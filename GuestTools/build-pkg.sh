#!/bin/bash
# build-pkg.sh -- Build the VortexGuestTools.pkg installer package.
#
# This script compiles all guest-side components and packages them into
# a flat .pkg that can be installed inside a macOS guest VM. The package
# installs:
#
#   /Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver   (HAL plugin)
#   /usr/local/bin/VortexAudioDaemon                        (vsock daemon)
#   /Library/LaunchDaemons/com.vortex.audiodaemon.plist     (auto-start)
#
# A postinstall script restarts coreaudiod and loads the LaunchDaemon.
#
# Usage:
#   cd GuestTools && bash build-pkg.sh
#   # Or:
#   bash GuestTools/build-pkg.sh   (from the Vortex root)
#
# Output:
#   GuestTools/build/VortexGuestTools.pkg

set -euo pipefail

# Resolve the GuestTools directory (where this script lives).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PKG_ID="com.vortex.guest-tools"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGING_DIR="${BUILD_DIR}/staging"
SCRIPTS_DIR="${BUILD_DIR}/scripts"
PKG_PATH="${BUILD_DIR}/VortexGuestTools.pkg"

# -- Version resolution --
# Read from the VERSION file. Fall back to git describe if available,
# then to "0.0.0-unknown".
VERSION_FILE="${SCRIPT_DIR}/VERSION"
if [[ -f "${VERSION_FILE}" ]]; then
    PKG_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
    log "Version from VERSION file: ${PKG_VERSION}"
elif command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null; then
    PKG_VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-unknown")"
    log "Version from git describe: ${PKG_VERSION}"
else
    PKG_VERSION="0.0.0-unknown"
    log "WARNING: No VERSION file and no git -- using fallback version: ${PKG_VERSION}"
fi

# -- Helpers --

log() {
    echo "==> $1"
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

# -- Step 1: Build the HAL plugin --

log "Building VortexAudioPlugin.driver..."

# Use the top-level GuestTools Makefile 'plugin' target, which builds
# into build/VortexAudioPlugin.driver/.
make -C "${SCRIPT_DIR}" plugin

PLUGIN_BUNDLE="${BUILD_DIR}/VortexAudioPlugin.driver"
[ -d "${PLUGIN_BUNDLE}/Contents/MacOS" ] || die "Plugin build failed: ${PLUGIN_BUNDLE} not found"
[ -x "${PLUGIN_BUNDLE}/Contents/MacOS/VortexAudioPlugin" ] || die "Plugin binary missing"

log "  Plugin built: ${PLUGIN_BUNDLE}"

# -- Step 2: Build the daemon --

log "Building VortexAudioDaemon..."

# Use the top-level GuestTools Makefile 'daemon' target.
make -C "${SCRIPT_DIR}" daemon

DAEMON_BINARY="${BUILD_DIR}/VortexAudioDaemon"
[ -x "${DAEMON_BINARY}" ] || die "Daemon build failed: ${DAEMON_BINARY} not found"

log "  Daemon built: ${DAEMON_BINARY}"

# -- Step 3: Create staging directory --

log "Creating staging directory..."

rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/Library/Audio/Plug-Ins/HAL"
mkdir -p "${STAGING_DIR}/usr/local/bin"
mkdir -p "${STAGING_DIR}/Library/LaunchDaemons"

# Copy the plugin bundle (preserve structure).
cp -R "${PLUGIN_BUNDLE}" "${STAGING_DIR}/Library/Audio/Plug-Ins/HAL/"

# Copy the daemon binary.
cp "${DAEMON_BINARY}" "${STAGING_DIR}/usr/local/bin/VortexAudioDaemon"
chmod 755 "${STAGING_DIR}/usr/local/bin/VortexAudioDaemon"

# Copy the LaunchDaemon plist.
cp "${SCRIPT_DIR}/VortexAudioDaemon/com.vortex.audiodaemon.plist" \
   "${STAGING_DIR}/Library/LaunchDaemons/com.vortex.audiodaemon.plist"
chmod 644 "${STAGING_DIR}/Library/LaunchDaemons/com.vortex.audiodaemon.plist"

# Embed the version file so the installed guest tools are self-describing.
mkdir -p "${STAGING_DIR}/usr/local/share/vortex"
echo "${PKG_VERSION}" > "${STAGING_DIR}/usr/local/share/vortex/VERSION"
chmod 644 "${STAGING_DIR}/usr/local/share/vortex/VERSION"

log "  Staging layout:"
log "    Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver/"
log "    usr/local/bin/VortexAudioDaemon"
log "    Library/LaunchDaemons/com.vortex.audiodaemon.plist"
log "    usr/local/share/vortex/VERSION (${PKG_VERSION})"

# -- Step 4: Prepare postinstall script --

log "Preparing installer scripts..."

rm -rf "${SCRIPTS_DIR}"
mkdir -p "${SCRIPTS_DIR}"
cp "${SCRIPT_DIR}/postinstall" "${SCRIPTS_DIR}/postinstall"
chmod 755 "${SCRIPTS_DIR}/postinstall"

# -- Step 5: Build the .pkg --

log "Building package..."

# Remove any previous package.
rm -f "${PKG_PATH}"

pkgbuild \
    --root "${STAGING_DIR}" \
    --identifier "${PKG_ID}" \
    --version "${PKG_VERSION}" \
    --install-location / \
    --scripts "${SCRIPTS_DIR}" \
    "${PKG_PATH}"

[ -f "${PKG_PATH}" ] || die "pkgbuild failed: ${PKG_PATH} not created"

# -- Step 6: Clean up staging --

rm -rf "${STAGING_DIR}"
rm -rf "${SCRIPTS_DIR}"

# -- Done --

PKG_SIZE=$(stat -f '%z' "${PKG_PATH}" 2>/dev/null || stat --printf='%s' "${PKG_PATH}" 2>/dev/null || echo "unknown")
log "Package built successfully:"
log "  ${PKG_PATH}"
log "  Size: ${PKG_SIZE} bytes"
log ""
log "To install inside a macOS guest VM:"
log "  sudo installer -pkg VortexGuestTools.pkg -target /"
