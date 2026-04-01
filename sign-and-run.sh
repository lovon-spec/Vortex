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

swift build --target "$TARGET" 2>&1 | tail -3

# Find the binary — path differs between toolchains
BIN=$(find .build -name "$TARGET" -type f -perm +111 ! -path "*.build/*" 2>/dev/null | head -1)
if [ -z "$BIN" ]; then
    echo "error: $TARGET binary not found after build"
    exit 1
fi

codesign --sign - --entitlements Vortex.entitlements --force "$BIN" 2>/dev/null
echo "[signed] $BIN"

if [ $# -gt 0 ]; then
    "$BIN" "$@"
fi
