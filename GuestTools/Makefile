# GuestTools/Makefile -- Top-level build for guest-side components.
#
# Builds:
#   1. VortexAudioPlugin.driver  (HAL AudioServerPlugin bundle)
#   2. VortexAudioDaemon          (vsock audio bridge daemon)
#
# Both are installed inside the macOS guest VM:
#   - Plugin: /Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver
#   - Daemon: /usr/local/bin/VortexAudioDaemon
#   - Plist:  /Library/LaunchDaemons/com.vortex.audiodaemon.plist
#
# Usage:
#   make              # Build both components
#   make plugin       # Build the HAL plugin only
#   make daemon       # Build the daemon only
#   make install      # Install both (requires sudo)
#   make clean        # Clean all build artifacts

# -- Toolchain --
CC       := clang
SWIFTC   := swiftc

# -- Paths --
BUILDDIR := build
SDK      := $(shell xcrun --show-sdk-path)
ARCH     := -arch arm64

# -- Plugin settings --
PLUGIN_SRC     := VortexAudioPlugin/VortexAudioPlugin.c
PLUGIN_HDR     := VortexAudioPlugin/VortexSharedAudio.h
PLUGIN_BUNDLE  := $(BUILDDIR)/VortexAudioPlugin.driver
PLUGIN_CONTENTS:= $(PLUGIN_BUNDLE)/Contents
PLUGIN_MACOSDIR:= $(PLUGIN_CONTENTS)/MacOS
PLUGIN_BINARY  := $(PLUGIN_MACOSDIR)/VortexAudioPlugin
PLUGIN_PLIST   := VortexAudioPlugin/Info.plist

PLUGIN_CFLAGS  := -std=c11 \
                  $(ARCH) \
                  -isysroot $(SDK) \
                  -mmacosx-version-min=14.0 \
                  -Wall -Wextra -Wpedantic -Werror \
                  -Wno-gnu-zero-variadic-macro-arguments \
                  -O2 \
                  -fvisibility=hidden

PLUGIN_LDFLAGS := $(ARCH) \
                  -isysroot $(SDK) \
                  -mmacosx-version-min=14.0 \
                  -bundle \
                  -framework CoreFoundation \
                  -framework CoreAudio \
                  -Wl,-exported_symbol,_VortexAudio_Create

# -- Daemon settings --
DAEMON_SRC     := VortexAudioDaemon/VortexAudioDaemon.swift
DAEMON_HDR     := VortexAudioDaemon/shm_bridge.h
DAEMON_BINARY  := $(BUILDDIR)/VortexAudioDaemon
DAEMON_PLIST   := VortexAudioDaemon/com.vortex.audiodaemon.plist

DAEMON_SWIFTFLAGS := -sdk $(SDK) \
                     -target arm64-apple-macos14.0 \
                     -parse-as-library \
                     -import-objc-header $(DAEMON_HDR) \
                     -O

# -- Targets --

.PHONY: all plugin daemon clean install uninstall

all: plugin daemon

# -- Plugin --

plugin: $(PLUGIN_BINARY) $(PLUGIN_CONTENTS)/Info.plist

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(PLUGIN_MACOSDIR): | $(BUILDDIR)
	mkdir -p $(PLUGIN_MACOSDIR)

$(PLUGIN_BINARY): $(PLUGIN_SRC) $(PLUGIN_HDR) | $(PLUGIN_MACOSDIR)
	$(CC) $(PLUGIN_CFLAGS) $(PLUGIN_LDFLAGS) -o $@ $(PLUGIN_SRC)

$(PLUGIN_CONTENTS)/Info.plist: $(PLUGIN_PLIST) | $(PLUGIN_MACOSDIR)
	cp $(PLUGIN_PLIST) $(PLUGIN_CONTENTS)/Info.plist

# -- Daemon --

daemon: $(DAEMON_BINARY)

$(DAEMON_BINARY): $(DAEMON_SRC) $(DAEMON_HDR) | $(BUILDDIR)
	$(SWIFTC) $(DAEMON_SWIFTFLAGS) -o $@ $(DAEMON_SRC)

# -- Install (requires root) --

install: all
	@echo "=== Installing GuestTools (requires sudo) ==="
	@echo ""
	@echo "Installing VortexAudioPlugin.driver..."
	sudo mkdir -p /Library/Audio/Plug-Ins/HAL
	sudo cp -R $(PLUGIN_BUNDLE) /Library/Audio/Plug-Ins/HAL/
	@echo ""
	@echo "Installing VortexAudioDaemon..."
	sudo install -m 755 $(DAEMON_BINARY) /usr/local/bin/VortexAudioDaemon
	@echo ""
	@echo "Installing LaunchDaemon plist..."
	sudo cp $(DAEMON_PLIST) /Library/LaunchDaemons/com.vortex.audiodaemon.plist
	sudo launchctl load /Library/LaunchDaemons/com.vortex.audiodaemon.plist 2>/dev/null || true
	@echo ""
	@echo "Restarting coreaudiod to load the plugin..."
	sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
	@echo ""
	@echo "Done. The 'Vortex Audio' device should appear in Audio MIDI Setup."
	@echo "The daemon will start automatically and connect to the host."

# -- Uninstall --

uninstall:
	@echo "=== Uninstalling GuestTools ==="
	sudo launchctl unload /Library/LaunchDaemons/com.vortex.audiodaemon.plist 2>/dev/null || true
	sudo rm -f /Library/LaunchDaemons/com.vortex.audiodaemon.plist
	sudo rm -f /usr/local/bin/VortexAudioDaemon
	sudo rm -rf /Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver
	sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
	@echo "Done."

# -- Clean --

clean:
	rm -rf $(BUILDDIR)
