#!/usr/bin/env bash
# Verify Vortex's bundled AArch64 EDK2 firmware checksum manifest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIRMWARE_DIR="${1:-${ROOT_DIR}/Sources/VortexGUI/Resources/Firmware}"

if [ ! -d "${FIRMWARE_DIR}" ]; then
    echo "error: firmware directory not found: ${FIRMWARE_DIR}" >&2
    exit 1
fi

if [ ! -f "${FIRMWARE_DIR}/SHA256SUMS" ]; then
    echo "error: SHA256SUMS not found in ${FIRMWARE_DIR}" >&2
    exit 1
fi

(cd "${FIRMWARE_DIR}" && shasum -a 256 -c SHA256SUMS)
