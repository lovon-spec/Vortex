#!/bin/bash
# Build, sign with entitlements, and run VortexCLI
set -e
cd "$(dirname "$0")"
swift build --target VortexCLI 2>&1 | tail -3
codesign --sign - --entitlements Vortex.entitlements --force .build/debug/VortexCLI 2>/dev/null
echo "[signed] .build/debug/VortexCLI"
if [ $# -gt 0 ]; then
    .build/debug/VortexCLI "$@"
fi
