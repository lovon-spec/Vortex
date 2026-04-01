#!/bin/bash
# build-release.sh -- Full release build, sign, package, and DMG creation.
#
# This script automates the complete release pipeline:
#   1. Swift release build (VortexCLI + VortexGUI)
#   2. Code signing with entitlements
#   3. .app bundle creation
#   4. Guest tools .pkg build
#   5. DMG creation containing Vortex.app + VortexGuestTools.pkg
#   6. SHA-256 checksums
#
# Usage:
#   bash scripts/build-release.sh
#   SIGNING_ID="Developer ID Application: ..." bash scripts/build-release.sh
#
# Environment:
#   SIGNING_ID   Code signing identity (default: ad-hoc "-")

set -euo pipefail

# -- Configuration --
SIGNING_ID="${SIGNING_ID:--}"

# Resolve project root (one level up from scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="${ROOT_DIR}/.build"
ENTITLEMENTS="${ROOT_DIR}/Vortex.entitlements"
GUEST_DIR="${ROOT_DIR}/GuestTools"

APP_BUNDLE="${BUILD_DIR}/Vortex.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"

DMG_NAME="Vortex.dmg"
DMG_STAGING="${BUILD_DIR}/dmg-staging"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

# -- Helpers --

log() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

find_binary() {
    local config="$1"
    local name="$2"
    local bin="${BUILD_DIR}/${config}/${name}"
    if [ ! -x "${bin}" ]; then
        bin="${BUILD_DIR}/arm64-apple-macosx/${config}/${name}"
    fi
    if [ ! -x "${bin}" ]; then
        return 1
    fi
    echo "${bin}"
}

# ============================================================
# Step 1: Release build
# ============================================================

log "Step 1/6: Swift release build"

swift build -c release

echo "Build complete."

# ============================================================
# Step 2: Code signing
# ============================================================

log "Step 2/6: Code signing (identity: ${SIGNING_ID})"

for name in VortexCLI VortexGUI; do
    bin=$(find_binary release "${name}") || {
        echo "  skip: ${name} (binary not found)"
        continue
    }
    codesign --sign "${SIGNING_ID}" --entitlements "${ENTITLEMENTS}" --force "${bin}" 2>/dev/null
    echo "  [signed] ${bin}"
done

# ============================================================
# Step 3: Create .app bundle
# ============================================================

log "Step 3/6: Creating Vortex.app bundle"

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_MACOS}"

gui_bin=$(find_binary release "VortexGUI") || die "VortexGUI release binary not found"
cp "${gui_bin}" "${APP_MACOS}/VortexGUI"

cat > "${APP_CONTENTS}/Info.plist" <<'PLIST'
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

# Copy entitlements into bundle for reference.
cp "${ENTITLEMENTS}" "${APP_CONTENTS}/Vortex.entitlements"

codesign --sign "${SIGNING_ID}" --entitlements "${ENTITLEMENTS}" --force "${APP_BUNDLE}" 2>/dev/null
echo "[signed] ${APP_BUNDLE}"

# ============================================================
# Step 4: Build guest tools .pkg
# ============================================================

log "Step 4/6: Building guest tools package"

cd "${GUEST_DIR}" && bash build-pkg.sh
cd "${ROOT_DIR}"

GUEST_PKG="${GUEST_DIR}/build/VortexGuestTools.pkg"
if [ -f "${GUEST_PKG}" ]; then
    echo "Guest tools package: ${GUEST_PKG}"
else
    echo "WARNING: Guest tools package was not created"
fi

# ============================================================
# Step 5: Create DMG
# ============================================================

log "Step 5/6: Creating ${DMG_NAME}"

rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"

cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"

if [ -f "${GUEST_PKG}" ]; then
    cp "${GUEST_PKG}" "${DMG_STAGING}/"
    echo "  Included: VortexGuestTools.pkg"
fi

rm -f "${DMG_PATH}"
hdiutil create \
    -volname Vortex \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${DMG_STAGING}"

echo "DMG created: ${DMG_PATH}"

# ============================================================
# Step 6: Checksums
# ============================================================

log "Step 6/6: Checksums"

echo ""
echo "Release artifacts:"
echo "  ${APP_BUNDLE}"
echo "  ${DMG_PATH}"
if [ -f "${GUEST_PKG}" ]; then
    echo "  ${GUEST_PKG}"
fi

echo ""
echo "SHA-256:"
shasum -a 256 "${DMG_PATH}"
if [ -f "${GUEST_PKG}" ]; then
    shasum -a 256 "${GUEST_PKG}"
fi

cli_bin=$(find_binary release "VortexCLI") && shasum -a 256 "${cli_bin}" || true

echo ""
echo "Release build complete."
