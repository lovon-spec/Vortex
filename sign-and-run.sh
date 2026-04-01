#!/bin/bash
# Build, sign with entitlements, and run Vortex targets
set -e
cd "$(dirname "$0")"

TARGET="${VORTEX_TARGET:-VortexCLI}"

# Support: ./sign-and-run.sh --gui <args>  =>  builds and runs VortexGUI
if [ "$1" = "--gui" ]; then
    TARGET="VortexGUI"
    shift
fi

swift build 2>&1 | tail -3

# Find the binary — check both known SPM output paths
BIN=".build/debug/$TARGET"
if [ ! -x "$BIN" ]; then
    BIN=".build/arm64-apple-macosx/debug/$TARGET"
fi
if [ ! -x "$BIN" ]; then
    echo "error: $TARGET binary not found at .build/debug/ or .build/arm64-apple-macosx/debug/"
    exit 1
fi

# For GUI target, wrap in a .app bundle so macOS grants TCC permissions (microphone, etc.)
if [ "$TARGET" = "VortexGUI" ]; then
    APP_DIR=".build/Vortex.app/Contents/MacOS"
    mkdir -p "$APP_DIR"
    cp "$BIN" "$APP_DIR/VortexGUI"

    cat > ".build/Vortex.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VortexGUI</string>
    <key>CFBundleIdentifier</key>
    <string>com.vortex.app</string>
    <key>CFBundleName</key>
    <string>Vortex</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Vortex needs microphone access to capture audio for VM input routing.</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

    BIN="$APP_DIR/VortexGUI"
    codesign --sign - --entitlements Vortex.entitlements --force ".build/Vortex.app" 2>/dev/null
    echo "[signed] .build/Vortex.app"

    if [ $# -gt 0 ]; then
        open -a ".build/Vortex.app" --args "$@"
    else
        open -a ".build/Vortex.app"
    fi
else
    codesign --sign - --entitlements Vortex.entitlements --force "$BIN" 2>/dev/null
    echo "[signed] $BIN"

    if [ $# -gt 0 ]; then
        "$BIN" "$@"
    fi
fi
