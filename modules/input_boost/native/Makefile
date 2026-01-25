# Makefile for Input Boost Daemon
# Cross-compile for Android aarch64 using NDK

NDK ?= $(ANDROID_NDK_HOME)
ifeq ($(NDK),)
    NDK := $(HOME)/android-ndk
endif

TOOLCHAIN := $(NDK)/toolchains/llvm/prebuilt/linux-x86_64
CC := $(TOOLCHAIN)/bin/aarch64-linux-android21-clang
STRIP := $(TOOLCHAIN)/bin/llvm-strip

CFLAGS := -Wall -Wextra -Werror -O2 -static -DANDROID
CFLAGS += -Wno-unused-parameter
CFLAGS += -ffunction-sections -fdata-sections
LDFLAGS := -static -Wl,--gc-sections

TARGET := input_boost_daemon
SRC := input_boost.c

.PHONY: all clean install check-ndk

all: check-ndk $(TARGET)

check-ndk:
	@if [ ! -d "$(TOOLCHAIN)" ]; then \
		echo "Error: Android NDK not found at $(NDK)"; \
		echo "Set NDK environment variable or ANDROID_NDK_HOME"; \
		echo "Example: make NDK=/path/to/android-ndk"; \
		exit 1; \
	fi

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	$(STRIP) $@
	@echo "Built: $@ ($(shell stat -c%s $@ 2>/dev/null || echo '?') bytes)"

clean:
	rm -f $(TARGET)

install: $(TARGET)
	@echo "Push to device:"
	@echo "  adb push $(TARGET) /data/local/tmp/"
	@echo "  adb shell chmod 755 /data/local/tmp/$(TARGET)"
