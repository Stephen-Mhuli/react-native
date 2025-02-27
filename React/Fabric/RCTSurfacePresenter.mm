/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTSurfacePresenter.h"

#import <mutex>

#import <React/RCTAssert.h>
#import <React/RCTBridge+Private.h>
#import <React/RCTComponentViewFactory.h>
#import <React/RCTComponentViewRegistry.h>
#import <React/RCTConstants.h>
#import <React/RCTFabricSurface.h>
#import <React/RCTFollyConvert.h>
#import <React/RCTI18nUtil.h>
#import <React/RCTMountingManager.h>
#import <React/RCTMountingManagerDelegate.h>
#import <React/RCTScheduler.h>
#import <React/RCTSurfaceRegistry.h>
#import <React/RCTSurfaceView+Internal.h>
#import <React/RCTSurfaceView.h>
#import <React/RCTUtils.h>

#import <react/config/ReactNativeConfig.h>
#import <react/renderer/componentregistry/ComponentDescriptorFactory.h>
#import <react/renderer/runtimescheduler/RuntimeScheduler.h>
#import <react/renderer/scheduler/AsynchronousEventBeat.h>
#import <react/renderer/scheduler/SchedulerToolbox.h>
#import <react/renderer/scheduler/SynchronousEventBeat.h>
#import <react/utils/ContextContainer.h>
#import <react/utils/ManagedObjectWrapper.h>

#import "PlatformRunLoopObserver.h"
#import "RCTConversions.h"

using namespace facebook::react;

static dispatch_queue_t RCTGetBackgroundQueue()
{
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_queue_attr_t attr =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    queue = dispatch_queue_create("com.facebook.react.background", attr);
  });
  return queue;
}

static BackgroundExecutor RCTGetBackgroundExecutor()
{
  return [](std::function<void()> &&callback) {
    if (RCTIsMainQueue()) {
      callback();
      return;
    }

    auto copyableCallback = callback;
    dispatch_async(RCTGetBackgroundQueue(), ^{
      copyableCallback();
    });
  };
}

@interface RCTSurfacePresenter () <RCTSchedulerDelegate, RCTMountingManagerDelegate>
@end

@implementation RCTSurfacePresenter {
  RCTMountingManager *_mountingManager; // Thread-safe.
  RCTSurfaceRegistry *_surfaceRegistry; // Thread-safe.

  std::mutex _schedulerAccessMutex;
  std::mutex _schedulerLifeCycleMutex;
  RCTScheduler *_Nullable _scheduler; // Thread-safe. Pointer is protected by `_schedulerAccessMutex`.
  ContextContainer::Shared _contextContainer; // Protected by `_schedulerLifeCycleMutex`.
  RuntimeExecutor _runtimeExecutor; // Protected by `_schedulerLifeCycleMutex`.

  butter::shared_mutex _observerListMutex;
  NSMutableArray<id<RCTSurfacePresenterObserver>> *_observers;
}

- (instancetype)initWithContextContainer:(ContextContainer::Shared)contextContainer
                         runtimeExecutor:(RuntimeExecutor)runtimeExecutor
{
  if (self = [super init]) {
    assert(contextContainer && "RuntimeExecutor must be not null.");
    _runtimeExecutor = runtimeExecutor;
    _contextContainer = contextContainer;

    _surfaceRegistry = [RCTSurfaceRegistry new];
    _mountingManager = [RCTMountingManager new];
    _mountingManager.contextContainer = contextContainer;
    _mountingManager.delegate = self;

    _observers = [NSMutableArray array];

    _scheduler = [self _createScheduler];
  }

  return self;
}

- (RCTMountingManager *)mountingManager
{
  return _mountingManager;
}

- (RCTScheduler *_Nullable)_scheduler
{
  std::lock_guard<std::mutex> lock(_schedulerAccessMutex);
  return _scheduler;
}

- (ContextContainer::Shared)contextContainer
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  return _contextContainer;
}

- (void)setContextContainer:(ContextContainer::Shared)contextContainer
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  _contextContainer = contextContainer;
  _mountingManager.contextContainer = contextContainer;
}

- (RuntimeExecutor)runtimeExecutor
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  return _runtimeExecutor;
}

- (void)setRuntimeExecutor:(RuntimeExecutor)runtimeExecutor
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  _runtimeExecutor = runtimeExecutor;
}

#pragma mark - Internal Surface-dedicated Interface

- (void)registerSurface:(RCTFabricSurface *)surface
{
  [_surfaceRegistry registerSurface:surface];
  RCTScheduler *scheduler = [self _scheduler];
  if (scheduler) {
    [scheduler registerSurface:surface.surfaceHandler];
  }
}

- (void)unregisterSurface:(RCTFabricSurface *)surface
{
  RCTScheduler *scheduler = [self _scheduler];
  if (scheduler) {
    [scheduler unregisterSurface:surface.surfaceHandler];
  }
  [_surfaceRegistry unregisterSurface:surface];
}

- (RCTFabricSurface *)surfaceForRootTag:(ReactTag)rootTag
{
  return [_surfaceRegistry surfaceForRootTag:rootTag];
}

- (UIView *)findComponentViewWithTag_DO_NOT_USE_DEPRECATED:(NSInteger)tag
{
  UIView<RCTComponentViewProtocol> *componentView =
      [_mountingManager.componentViewRegistry findComponentViewWithTag:tag];
  return componentView;
}

- (BOOL)synchronouslyUpdateViewOnUIThread:(NSNumber *)reactTag props:(NSDictionary *)props
{
  RCTScheduler *scheduler = [self _scheduler];
  if (!scheduler) {
    return NO;
  }

  ReactTag tag = [reactTag integerValue];
  UIView<RCTComponentViewProtocol> *componentView =
      [_mountingManager.componentViewRegistry findComponentViewWithTag:tag];
  if (componentView == nil) {
    return NO; // This view probably isn't managed by Fabric
  }
  ComponentHandle handle = [[componentView class] componentDescriptorProvider].handle;
  auto *componentDescriptor = [scheduler findComponentDescriptorByHandle_DO_NOT_USE_THIS_IS_BROKEN:handle];

  if (!componentDescriptor) {
    return YES;
  }

  [_mountingManager synchronouslyUpdateViewOnUIThread:tag changedProps:props componentDescriptor:*componentDescriptor];
  return YES;
}

- (void)setupAnimationDriverWithSurfaceHandler:(facebook::react::SurfaceHandler const &)surfaceHandler
{
  [[self _scheduler] setupAnimationDriver:surfaceHandler];
}

- (BOOL)suspend
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);

  RCTScheduler *scheduler;
  {
    std::lock_guard<std::mutex> accessLock(_schedulerAccessMutex);

    if (!_scheduler) {
      return NO;
    }
    scheduler = _scheduler;
    _scheduler = nil;
  }

  [self _stopAllSurfacesWithScheduler:scheduler];

  return YES;
}

- (BOOL)resume
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);

  RCTScheduler *scheduler;
  {
    std::lock_guard<std::mutex> accessLock(_schedulerAccessMutex);

    if (_scheduler) {
      return NO;
    }
    scheduler = [self _createScheduler];
  }

  [self _startAllSurfacesWithScheduler:scheduler];

  {
    std::lock_guard<std::mutex> accessLock(_schedulerAccessMutex);
    _scheduler = scheduler;
  }

  return YES;
}

#pragma mark - Private

- (RCTScheduler *)_createScheduler
{
  auto reactNativeConfig = _contextContainer->at<std::shared_ptr<ReactNativeConfig const>>("ReactNativeConfig");

  if (reactNativeConfig && reactNativeConfig->getBool("react_fabric:preemptive_view_allocation_disabled_ios")) {
    RCTExperimentSetPreemptiveViewAllocationDisabled(YES);
  }

  auto componentRegistryFactory =
      [factory = wrapManagedObject(_mountingManager.componentViewRegistry.componentViewFactory)](
          EventDispatcher::Weak const &eventDispatcher, ContextContainer::Shared const &contextContainer) {
        return [(RCTComponentViewFactory *)unwrapManagedObject(factory)
            createComponentDescriptorRegistryWithParameters:{eventDispatcher, contextContainer}];
      };

  auto runtimeExecutor = _runtimeExecutor;

  auto toolbox = SchedulerToolbox{};
  toolbox.contextContainer = _contextContainer;
  toolbox.componentRegistryFactory = componentRegistryFactory;

  auto weakRuntimeScheduler = _contextContainer->find<std::weak_ptr<RuntimeScheduler>>("RuntimeScheduler");
  auto runtimeScheduler = weakRuntimeScheduler.hasValue() ? weakRuntimeScheduler.value().lock() : nullptr;
  if (runtimeScheduler) {
    runtimeScheduler->setEnableYielding(
        reactNativeConfig->getBool("react_native_new_architecture:runtimescheduler_enable_yielding_ios"));
    runtimeExecutor = [runtimeScheduler](std::function<void(jsi::Runtime & runtime)> &&callback) {
      runtimeScheduler->scheduleWork(std::move(callback));
    };
  }

  toolbox.runtimeExecutor = runtimeExecutor;

  toolbox.mainRunLoopObserverFactory = [](RunLoopObserver::Activity activities,
                                          RunLoopObserver::WeakOwner const &owner) {
    return std::make_unique<MainRunLoopObserver>(activities, owner);
  };

  toolbox.backgroundExecutor = RCTGetBackgroundExecutor();

  toolbox.synchronousEventBeatFactory =
      [runtimeExecutor, runtimeScheduler = runtimeScheduler](EventBeat::SharedOwnerBox const &ownerBox) {
        auto runLoopObserver =
            std::make_unique<MainRunLoopObserver const>(RunLoopObserver::Activity::BeforeWaiting, ownerBox->owner);
        return std::make_unique<SynchronousEventBeat>(std::move(runLoopObserver), runtimeExecutor, runtimeScheduler);
      };

  toolbox.asynchronousEventBeatFactory =
      [runtimeExecutor](EventBeat::SharedOwnerBox const &ownerBox) -> std::unique_ptr<EventBeat> {
    auto runLoopObserver =
        std::make_unique<MainRunLoopObserver const>(RunLoopObserver::Activity::BeforeWaiting, ownerBox->owner);
    return std::make_unique<AsynchronousEventBeat>(std::move(runLoopObserver), runtimeExecutor);
  };

  RCTScheduler *scheduler = [[RCTScheduler alloc] initWithToolbox:toolbox];
  scheduler.delegate = self;

  return scheduler;
}

- (void)_startAllSurfacesWithScheduler:(RCTScheduler *)scheduler
{
  [_surfaceRegistry enumerateWithBlock:^(NSEnumerator<RCTFabricSurface *> *enumerator) {
    for (RCTFabricSurface *surface in enumerator) {
      [scheduler registerSurface:surface.surfaceHandler];
      [surface start];
    }
  }];
}

- (void)_stopAllSurfacesWithScheduler:(RCTScheduler *)scheduler
{
  [_surfaceRegistry enumerateWithBlock:^(NSEnumerator<RCTFabricSurface *> *enumerator) {
    for (RCTFabricSurface *surface in enumerator) {
      [surface stop];
      [scheduler unregisterSurface:surface.surfaceHandler];
    }
  }];
}

#pragma mark - RCTSchedulerDelegate

- (void)schedulerDidFinishTransaction:(MountingCoordinator::Shared const &)mountingCoordinator
{
  [_mountingManager scheduleTransaction:mountingCoordinator];
}

- (void)schedulerDidDispatchCommand:(ShadowView const &)shadowView
                        commandName:(std::string const &)commandName
                               args:(folly::dynamic const &)args
{
  ReactTag tag = shadowView.tag;
  NSString *commandStr = [[NSString alloc] initWithUTF8String:commandName.c_str()];
  NSArray *argsArray = convertFollyDynamicToId(args);

  [self->_mountingManager dispatchCommand:tag commandName:commandStr args:argsArray];
}

- (void)schedulerDidSendAccessibilityEvent:(const facebook::react::ShadowView &)shadowView
                                 eventType:(const std::string &)eventType
{
  ReactTag tag = shadowView.tag;
  NSString *eventTypeStr = [[NSString alloc] initWithUTF8String:eventType.c_str()];

  [self->_mountingManager sendAccessibilityEvent:tag eventType:eventTypeStr];
}

- (void)schedulerDidSetIsJSResponder:(BOOL)isJSResponder
                blockNativeResponder:(BOOL)blockNativeResponder
                       forShadowView:(facebook::react::ShadowView const &)shadowView;
{
  [self->_mountingManager setIsJSResponder:isJSResponder
                      blockNativeResponder:blockNativeResponder
                             forShadowView:shadowView];
}

- (void)addObserver:(id<RCTSurfacePresenterObserver>)observer
{
  std::unique_lock<butter::shared_mutex> lock(_observerListMutex);
  [self->_observers addObject:observer];
}

- (void)removeObserver:(id<RCTSurfacePresenterObserver>)observer
{
  std::unique_lock<butter::shared_mutex> lock(_observerListMutex);
  [self->_observers removeObject:observer];
}

#pragma mark - RCTMountingManagerDelegate

- (void)mountingManager:(RCTMountingManager *)mountingManager willMountComponentsWithRootTag:(ReactTag)rootTag
{
  RCTAssertMainQueue();

  std::shared_lock<butter::shared_mutex> lock(_observerListMutex);
  for (id<RCTSurfacePresenterObserver> observer in _observers) {
    if ([observer respondsToSelector:@selector(willMountComponentsWithRootTag:)]) {
      [observer willMountComponentsWithRootTag:rootTag];
    }
  }
}

- (void)mountingManager:(RCTMountingManager *)mountingManager didMountComponentsWithRootTag:(ReactTag)rootTag
{
  RCTAssertMainQueue();

  std::shared_lock<butter::shared_mutex> lock(_observerListMutex);
  for (id<RCTSurfacePresenterObserver> observer in _observers) {
    if ([observer respondsToSelector:@selector(didMountComponentsWithRootTag:)]) {
      [observer didMountComponentsWithRootTag:rootTag];
    }
  }
}

@end
