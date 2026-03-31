# Makefile -- Build VortexAudioPlugin.driver HAL AudioServerPlugin bundle.
#
# Output:
#   build/VortexAudioPlugin.driver/
#     Contents/
#       Info.plist
#       MacOS/
#         VortexAudioPlugin   (Mach-O dylib)
#
# Installation (requires root):
#   sudo cp -R build/VortexAudioPlugin.driver /Library/Audio/Plug-Ins/HAL/
#   sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
#
# Uninstallation:
#   sudo rm -rf /Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver
#   sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod

# -- Toolchain --
CC       := clang
INSTALL  := install

# -- Paths --
SRCDIR   := .
BUILDDIR := build
BUNDLE   := $(BUILDDIR)/VortexAudioPlugin.driver
CONTENTS := $(BUNDLE)/Contents
MACOSDIR := $(CONTENTS)/MacOS

# -- Source files --
SOURCES  := $(SRCDIR)/VortexAudioPlugin.c

# -- Build flags --
ARCH     := -arch arm64
SDK      := $(shell xcrun --show-sdk-path)

CFLAGS   := -std=c11 \
            $(ARCH) \
            -isysroot $(SDK) \
            -mmacosx-version-min=14.0 \
            -Wall -Wextra -Wpedantic -Werror \
            -Wno-gnu-zero-variadic-macro-arguments \
            -O2 \
            -fvisibility=hidden

LDFLAGS  := $(ARCH) \
            -isysroot $(SDK) \
            -mmacosx-version-min=14.0 \
            -bundle \
            -framework CoreFoundation \
            -framework CoreAudio

# Export the factory function so CFPlugIn can find it.
LDFLAGS  += -Wl,-exported_symbol,_VortexAudio_Create

# -- Targets --
BINARY   := $(MACOSDIR)/VortexAudioPlugin

.PHONY: all clean install uninstall test

all: $(BINARY) $(CONTENTS)/Info.plist

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(MACOSDIR): | $(BUILDDIR)
	mkdir -p $(MACOSDIR)

$(BINARY): $(SOURCES) | $(MACOSDIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES)

$(CONTENTS)/Info.plist: $(SRCDIR)/Info.plist | $(MACOSDIR)
	cp $(SRCDIR)/Info.plist $(CONTENTS)/Info.plist

clean:
	rm -rf $(BUILDDIR)

install: all
	@echo "Installing VortexAudioPlugin.driver to /Library/Audio/Plug-Ins/HAL/"
	@echo "This requires root privileges."
	sudo mkdir -p /Library/Audio/Plug-Ins/HAL
	sudo cp -R $(BUNDLE) /Library/Audio/Plug-Ins/HAL/
	@echo "Restarting coreaudiod..."
	sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
	@echo "Done. The 'Vortex Audio' device should now appear in Audio MIDI Setup."

uninstall:
	@echo "Removing VortexAudioPlugin.driver..."
	sudo rm -rf /Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver
	@echo "Restarting coreaudiod..."
	sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
	@echo "Done."

# Quick sanity test: build, install, and check that the device appears.
test: install
	@echo "Checking for Vortex Audio device..."
	@system_profiler SPAudioDataType 2>/dev/null | grep -q "Vortex Audio" \
		&& echo "SUCCESS: Vortex Audio device found." \
		|| echo "WARN: Vortex Audio not found in system_profiler output (may need a moment)."
