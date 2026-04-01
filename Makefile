# Makefile -- Vortex top-level build pipeline.
#
# Targets:
#   make             Build (debug), sign, and build guest tools
#   make build       Swift debug build
#   make release     Swift release build
#   make sign        Codesign binaries with Vortex.entitlements
#   make guest-tools Build guest-side HAL plugin + daemon (.pkg)
#   make app         Create .build/Vortex.app bundle (release, signed)
#   make dmg         Create Vortex.dmg with Vortex.app + VortexGuestTools.pkg
#   make clean       Remove all build artifacts
#
# Configuration:
#   CONFIGURATION   debug or release (default: debug, except for 'release'/'app'/'dmg')
#   SIGNING_ID      Code signing identity (default: ad-hoc "-")

SHELL          := /bin/bash
CONFIGURATION  ?= debug
SIGNING_ID     ?= -

# -- Derived paths --
ROOT_DIR       := $(shell pwd)
BUILD_DIR      := $(ROOT_DIR)/.build
ENTITLEMENTS   := $(ROOT_DIR)/Vortex.entitlements
GUEST_DIR      := $(ROOT_DIR)/GuestTools

# -- App bundle paths --
APP_BUNDLE     := $(BUILD_DIR)/Vortex.app
APP_CONTENTS   := $(APP_BUNDLE)/Contents
APP_MACOS      := $(APP_CONTENTS)/MacOS

# -- DMG --
DMG_NAME       := Vortex.dmg
DMG_STAGING    := $(BUILD_DIR)/dmg-staging
DMG_PATH       := $(BUILD_DIR)/$(DMG_NAME)

# ============================================================
# Phony targets
# ============================================================

.PHONY: all build release clean sign guest-tools app dmg

all: build sign guest-tools

# ============================================================
# Build
# ============================================================

build:
	swift build

release:
	swift build -c release
	@$(MAKE) --no-print-directory sign CONFIGURATION=release

# ============================================================
# Code signing
# ============================================================

sign:
	@for name in VortexCLI VortexGUI; do \
		bin="$(BUILD_DIR)/$(CONFIGURATION)/$$name"; \
		if [ ! -x "$$bin" ]; then \
			bin="$(BUILD_DIR)/arm64-apple-macosx/$(CONFIGURATION)/$$name"; \
		fi; \
		if [ -x "$$bin" ]; then \
			codesign --sign "$(SIGNING_ID)" --entitlements "$(ENTITLEMENTS)" --force "$$bin" 2>/dev/null; \
			echo "[signed] $$bin"; \
		fi; \
	done

# ============================================================
# Guest tools
# ============================================================

guest-tools:
	cd "$(GUEST_DIR)" && bash build-pkg.sh

# ============================================================
# App bundle (always release)
# ============================================================

app: release
	@echo "==> Creating Vortex.app bundle..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_MACOS)"
	@gui="$(BUILD_DIR)/release/VortexGUI"; \
	if [ ! -x "$$gui" ]; then \
		gui="$(BUILD_DIR)/arm64-apple-macosx/release/VortexGUI"; \
	fi; \
	if [ ! -x "$$gui" ]; then \
		echo "error: VortexGUI release binary not found"; exit 1; \
	fi; \
	cp "$$gui" "$(APP_MACOS)/VortexGUI"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleExecutable</key>' \
		'    <string>VortexGUI</string>' \
		'    <key>CFBundleIdentifier</key>' \
		'    <string>com.vortex.app</string>' \
		'    <key>CFBundleName</key>' \
		'    <string>Vortex</string>' \
		'    <key>CFBundleVersion</key>' \
		'    <string>1.0</string>' \
		'    <key>CFBundleShortVersionString</key>' \
		'    <string>1.0</string>' \
		'    <key>CFBundlePackageType</key>' \
		'    <string>APPL</string>' \
		'    <key>NSMicrophoneUsageDescription</key>' \
		'    <string>Vortex needs microphone access to capture audio for VM input routing.</string>' \
		'    <key>LSUIElement</key>' \
		'    <false/>' \
		'</dict>' \
		'</plist>' > "$(APP_CONTENTS)/Info.plist"
	codesign --sign "$(SIGNING_ID)" --entitlements "$(ENTITLEMENTS)" --force "$(APP_BUNDLE)" 2>/dev/null
	@echo "[signed] $(APP_BUNDLE)"

# ============================================================
# DMG
# ============================================================

dmg: app guest-tools
	@echo "==> Creating $(DMG_NAME)..."
	@rm -rf "$(DMG_STAGING)"
	@mkdir -p "$(DMG_STAGING)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/"
	@if [ -f "$(GUEST_DIR)/build/VortexGuestTools.pkg" ]; then \
		cp "$(GUEST_DIR)/build/VortexGuestTools.pkg" "$(DMG_STAGING)/"; \
	else \
		echo "warning: VortexGuestTools.pkg not found, DMG will not include guest tools"; \
	fi
	@rm -f "$(DMG_PATH)"
	hdiutil create \
		-volname Vortex \
		-srcfolder "$(DMG_STAGING)" \
		-ov \
		-format UDZO \
		"$(DMG_PATH)"
	@rm -rf "$(DMG_STAGING)"
	@echo "==> $(DMG_PATH)"
	@shasum -a 256 "$(DMG_PATH)"

# ============================================================
# Clean
# ============================================================

clean:
	swift package clean 2>/dev/null || true
	rm -rf "$(BUILD_DIR)"
	@$(MAKE) --no-print-directory -C "$(GUEST_DIR)" clean 2>/dev/null || true
