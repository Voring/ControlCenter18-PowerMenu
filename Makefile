TARGET := iphone:clang:16.5:16.0
ARCHS := arm64e

PACKAGE_VERSION := 1.7.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := C18PowerMenu
C18PowerMenu_FILES := Tweak.m
C18PowerMenu_FRAMEWORKS := UIKit Foundation
C18PowerMenu_CFLAGS := -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
