/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#pragma once

#include <jsi/jsi.h>
#include <react/renderer/core/ReactPrimitives.h>

namespace facebook::react {

class SurfaceRegistryBinding final {
 public:
  SurfaceRegistryBinding() = delete;

  /*
   * Starts React Native Surface with given id, moduleName, and props.
   * Thread synchronization must be enforced externally.
   */
  static void startSurface(
      jsi::Runtime &runtime,
      SurfaceId surfaceId,
      std::string const &moduleName,
      folly::dynamic const &initalProps,
      DisplayMode displayMode);

  /*
   * Updates the React Native Surface identified with surfaceId and moduleName
   * with the given props.
   * Thread synchronization must be enforced externally.
   */
  static void setSurfaceProps(
      jsi::Runtime &runtime,
      SurfaceId surfaceId,
      std::string const &moduleName,
      folly::dynamic const &initalProps,
      DisplayMode displayMode);

  /*
   * Stops React Native Surface with given id.
   * Thread synchronization must be enforced externally.
   */
  static void stopSurface(jsi::Runtime &runtime, SurfaceId surfaceId);
};

} // namespace facebook::react
