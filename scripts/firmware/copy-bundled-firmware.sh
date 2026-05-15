#!/usr/bin/env bash
# Copy and verify Vortex's bundled AArch64 EDK2 firmware into an app bundle.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <destination-firmware-directory>" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_DIR="${ROOT_DIR}/Sources/VortexGUI/Resources/Firmware"
DEST_DIR="$1"

if [ ! -f "${SOURCE_DIR}/SHA256SUMS" ]; then
    echo "error: missing firmware checksum manifest: ${SOURCE_DIR}/SHA256SUMS" >&2
    exit 1
fi

mkdir -p "${DEST_DIR}"
cp "${SOURCE_DIR}/edk2-aarch64-code.fd" "${DEST_DIR}/edk2-aarch64-code.fd"
cp "${SOURCE_DIR}/edk2-aarch64-code.fd.provenance.json" "${DEST_DIR}/edk2-aarch64-code.fd.provenance.json"
cp "${SOURCE_DIR}/SHA256SUMS" "${DEST_DIR}/SHA256SUMS"

(cd "${DEST_DIR}" && shasum -a 256 -c SHA256SUMS)
echo "[firmware] verified ${DEST_DIR}/edk2-aarch64-code.fd"
