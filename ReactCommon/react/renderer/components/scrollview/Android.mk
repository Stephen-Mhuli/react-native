# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE := rrc_scrollview

LOCAL_SRC_FILES := $(wildcard $(LOCAL_PATH)/*.cpp)

LOCAL_C_INCLUDES := $(LOCAL_PATH)/
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/../../../../

LOCAL_CFLAGS := \
  -DLOG_TAG=\"Fabric\"

LOCAL_CFLAGS += -fexceptions -frtti -std=c++17 -Wall

LOCAL_STATIC_LIBRARIES :=

LOCAL_SHARED_LIBRARIES := \
  glog \
  libfolly_futures \
  libfolly_json \
  libglog_init \
  libjsi \
  libreact_debug \
  libreact_render_core \
  libreact_render_debug \
  libreact_render_graphics \
  libreact_render_mapbuffer \
  librrc_view \
  libyoga

include $(BUILD_STATIC_LIBRARY)

$(call import-module,glog)
$(call import-module,folly)
$(call import-module,fbgloginit)
$(call import-module,react/renderer/components/view)
$(call import-module,react/renderer/core)
$(call import-module,react/renderer/debug)
$(call import-module,react/renderer/graphics)
$(call import-module,react/debug)
$(call import-module,yogajni)
$(call import-module,react/renderer/mapbuffer)
