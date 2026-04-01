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

codesign --sign - --entitlements Vortex.entitlements --force "$BIN" 2>/dev/null
echo "[signed] $BIN"

if [ $# -gt 0 ]; then
    "$BIN" "$@"
fi
