#!/usr/bin/env bash
# Verify QEMU's pinned AArch64 firmware release blob.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QEMU_REPO="https://gitlab.com/qemu-project/qemu.git"
QEMU_TAG="v10.2.2"
QEMU_COMMIT="f8ed81651e61d9c2166df6121ce2af0f44f06b3e"
QEMU_BLOB_SHA256="c023444108b7a132fdebf70c4765cd2dd9af2a9ff7d001a743aaabe87c20a458"
EXPECTED_SHA256="47765fe344818cbc464b1c14ae658fb4b854f5c2ceffa982411731eb4865594d"
EXPECTED_SIZE="67108864"

WORK_DIR="${ROOT_DIR}/.build/firmware/qemu-blob"
QEMU_DIR="${WORK_DIR}/qemu"
OUT_BZ2="${WORK_DIR}/edk2-aarch64-code.fd.bz2"
OUT_FD="${WORK_DIR}/edk2-aarch64-code.fd"
BUNDLED_FD="${ROOT_DIR}/Sources/VortexGUI/Resources/Firmware/edk2-aarch64-code.fd"

file_size() {
    if stat -c '%s' "$1" >/dev/null 2>&1; then
        stat -c '%s' "$1"
    else
        stat -f '%z' "$1"
    fi
}

sha256_hex() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

git clone --filter=blob:none --no-checkout --depth 1 --branch "${QEMU_TAG}" "${QEMU_REPO}" "${QEMU_DIR}"
actual_commit="$(git -C "${QEMU_DIR}" rev-parse "${QEMU_TAG}^{commit}")"
if [ "${actual_commit}" != "${QEMU_COMMIT}" ]; then
    echo "error: ${QEMU_TAG} resolved to ${actual_commit}, expected ${QEMU_COMMIT}" >&2
    exit 1
fi

git -C "${QEMU_DIR}" show "HEAD:pc-bios/edk2-aarch64-code.fd.bz2" > "${OUT_BZ2}"
actual_blob_hash="$(sha256_hex "${OUT_BZ2}")"
if [ "${actual_blob_hash}" != "${QEMU_BLOB_SHA256}" ]; then
    echo "error: QEMU firmware blob hash ${actual_blob_hash}, expected ${QEMU_BLOB_SHA256}" >&2
    exit 1
fi

bunzip2 -c "${OUT_BZ2}" > "${OUT_FD}"
actual_size="$(file_size "${OUT_FD}")"
actual_hash="$(sha256_hex "${OUT_FD}")"
if [ "${actual_size}" != "${EXPECTED_SIZE}" ]; then
    echo "error: decompressed firmware size ${actual_size}, expected ${EXPECTED_SIZE}" >&2
    exit 1
fi
if [ "${actual_hash}" != "${EXPECTED_SHA256}" ]; then
    echo "error: decompressed firmware hash ${actual_hash}, expected ${EXPECTED_SHA256}" >&2
    exit 1
fi

if [ "${VORTEX_VERIFY_QEMU_BLOB_MATCHES_BUNDLE:-0}" = "1" ] && [ -f "${BUNDLED_FD}" ]; then
    bundled_hash="$(sha256_hex "${BUNDLED_FD}")"
    if [ "${bundled_hash}" != "${EXPECTED_SHA256}" ]; then
        echo "error: bundled firmware hash ${bundled_hash}, expected ${EXPECTED_SHA256}" >&2
        exit 1
    fi
fi

echo "verified QEMU ${QEMU_TAG} firmware blob: ${EXPECTED_SHA256}"
