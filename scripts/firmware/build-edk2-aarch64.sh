#!/usr/bin/env bash
# Rebuild Vortex's AArch64 ArmVirtQemu EDK2 firmware from pinned sources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QEMU_REPO="https://gitlab.com/qemu-project/qemu.git"
QEMU_TAG="v10.2.2"
QEMU_COMMIT="f8ed81651e61d9c2166df6121ce2af0f44f06b3e"

EDK2_REPO="https://github.com/tianocore/edk2.git"
EDK2_COMMIT="4dfdca63a93497203f197ec98ba20e2327e4afe4"
EDK2_VERSION_OVERRIDE="edk2-stable202408-prebuilt.qemu.org"
EDK2_RELEASE_DATE="08/13/2024"

CONTAINER_IMAGE="ghcr.io/tianocore/containers/ubuntu-22-build@sha256:bcda96cb0b9a39a881122ab7d3be86e6151f4c66968421827384c97850c790a5"
EXPECTED_SHA256="47765fe344818cbc464b1c14ae658fb4b854f5c2ceffa982411731eb4865594d"
EXPECTED_SIZE="67108864"

WORK_DIR="${ROOT_DIR}/.build/firmware/edk2-aarch64"
QEMU_DIR="${WORK_DIR}/qemu"
EDK2_DIR="${QEMU_DIR}/roms/edk2"
OUT_DIR="${WORK_DIR}/out"
OUT_FD="${OUT_DIR}/edk2-aarch64-code.fd"
BUNDLED_DIR="${ROOT_DIR}/Sources/VortexGUI/Resources/Firmware"

INSTALL=0
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

usage() {
    cat <<'USAGE'
usage: scripts/firmware/build-edk2-aarch64.sh [--install] [--jobs N]

Builds ArmVirtQemu-AARCH64 from pinned QEMU build recipes, pinned upstream
tianocore/edk2 sources, and a pinned container image. The script verifies the
resulting pflash image against Vortex's recorded SHA-256 before it can replace
the bundled firmware.

Options:
  --install   Copy the verified firmware into Sources/VortexGUI/Resources/Firmware.
  --jobs N    Parallel build job count passed to EDK2 BaseTools.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install)
            INSTALL=1
            shift
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

find_container_engine() {
    if [ -n "${CONTAINER_ENGINE:-}" ]; then
        command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1 || {
            echo "error: CONTAINER_ENGINE=${CONTAINER_ENGINE} was not found" >&2
            exit 1
        }
        echo "${CONTAINER_ENGINE}"
        return
    fi
    if command -v docker >/dev/null 2>&1; then
        echo docker
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        echo podman
        return
    fi
    echo "error: Docker or Podman is required to run the pinned EDK2 build container" >&2
    exit 1
}

file_size() {
    if stat -f '%z' "$1" >/dev/null 2>&1; then
        stat -f '%z' "$1"
    else
        stat -c '%s' "$1"
    fi
}

assert_gitlink() {
    local repo_dir="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual="$(git -C "${repo_dir}" ls-tree HEAD "${path}" | awk '{print $3}')"
    if [ "${actual}" != "${expected}" ]; then
        echo "error: ${path} gitlink ${actual}, expected ${expected}" >&2
        exit 1
    fi
}

ENGINE="$(find_container_engine)"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${OUT_DIR}"

git clone --filter=blob:none --no-checkout --depth 1 --branch "${QEMU_TAG}" "${QEMU_REPO}" "${QEMU_DIR}"
actual_qemu_commit="$(git -C "${QEMU_DIR}" rev-parse "${QEMU_TAG}^{commit}")"
if [ "${actual_qemu_commit}" != "${QEMU_COMMIT}" ]; then
    echo "error: ${QEMU_TAG} resolved to ${actual_qemu_commit}, expected ${QEMU_COMMIT}" >&2
    exit 1
fi
git -C "${QEMU_DIR}" checkout --detach "${QEMU_COMMIT}"

rm -rf "${EDK2_DIR}"
git init "${EDK2_DIR}" >/dev/null
git -C "${EDK2_DIR}" remote add origin "${EDK2_REPO}"
git -C "${EDK2_DIR}" fetch --depth 1 origin "${EDK2_COMMIT}"
git -C "${EDK2_DIR}" checkout --detach FETCH_HEAD

assert_gitlink "${EDK2_DIR}" "ArmPkg/Library/ArmSoftFloatLib/berkeley-softfloat-3" "b64af41c3276f97f0e181920400ee056b9c88037"
assert_gitlink "${EDK2_DIR}" "BaseTools/Source/C/BrotliCompress/brotli" "f4153a09f87cbb9c826d8fc12c74642bb2d879ea"
assert_gitlink "${EDK2_DIR}" "CryptoPkg/Library/MbedTlsLib/mbedtls" "8c89224991adff88d53cd380f42a2baa36f91454"
assert_gitlink "${EDK2_DIR}" "CryptoPkg/Library/OpensslLib/openssl" "de90e54bbe82e5be4fb9608b6f5c308bb837d355"
assert_gitlink "${EDK2_DIR}" "MdeModulePkg/Library/BrotliCustomDecompressLib/brotli" "f4153a09f87cbb9c826d8fc12c74642bb2d879ea"
assert_gitlink "${EDK2_DIR}" "MdeModulePkg/Universal/RegularExpressionDxe/oniguruma" "abfc8ff81df4067f309032467785e06975678f0d"
assert_gitlink "${EDK2_DIR}" "MdePkg/Library/BaseFdtLib/libfdt" "cfff805481bdea27f900c32698171286542b8d3c"
assert_gitlink "${EDK2_DIR}" "MdePkg/Library/MipiSysTLib/mipisyst" "370b5944c046bab043dd8b133727b2135af7747a"
assert_gitlink "${EDK2_DIR}" "RedfishPkg/Library/JsonLib/jansson" "e9ebfa7e77a6bee77df44e096b100e7131044059"
assert_gitlink "${EDK2_DIR}" "SecurityPkg/DeviceSecurity/SpdmLib/libspdm" "50924a4c8145fc721e17208f55814d2b38766fe6"
assert_gitlink "${EDK2_DIR}" "UnitTestFrameworkPkg/Library/CmockaLib/cmocka" "1cc9cde3448cdd2e000886a26acf1caac2db7cf1"
assert_gitlink "${EDK2_DIR}" "UnitTestFrameworkPkg/Library/GoogleTestLib/googletest" "86add13493e5c881d7e4ba77fb91c1f57752b3a4"
assert_gitlink "${EDK2_DIR}" "UnitTestFrameworkPkg/Library/SubhookLib/subhook" "83d4e1ebef3588fae48b69a7352cc21801cb70bc"

git -C "${EDK2_DIR}" submodule update --init --recursive --depth 1

"${ENGINE}" pull "${CONTAINER_IMAGE}"
"${ENGINE}" run --rm \
    -v "${QEMU_DIR}:/work/qemu" \
    -v "${OUT_DIR}:/work/out" \
    -w /work/qemu/roms \
    "${CONTAINER_IMAGE}" \
    bash -lc "set -euo pipefail
python3 edk2-build.py \
  --config edk2-build.config \
  --version-override '${EDK2_VERSION_OVERRIDE}' \
  --release-date '${EDK2_RELEASE_DATE}' \
  --match armvirt.aa64 \
  --jobs '${JOBS}' \
  --silent --no-logs
cp ../pc-bios/edk2-aarch64-code.fd /work/out/edk2-aarch64-code.fd"

actual_size="$(file_size "${OUT_FD}")"
actual_hash="$(shasum -a 256 "${OUT_FD}" | awk '{print $1}')"
if [ "${actual_size}" != "${EXPECTED_SIZE}" ]; then
    echo "error: built firmware size ${actual_size}, expected ${EXPECTED_SIZE}" >&2
    exit 1
fi
if [ "${actual_hash}" != "${EXPECTED_SHA256}" ]; then
    echo "error: built firmware hash ${actual_hash}, expected ${EXPECTED_SHA256}" >&2
    exit 1
fi

if [ "${INSTALL}" -eq 1 ]; then
    cp "${OUT_FD}" "${BUNDLED_DIR}/edk2-aarch64-code.fd"
    (cd "${BUNDLED_DIR}" && shasum -a 256 -c SHA256SUMS)
fi

echo "built and verified ${OUT_FD}: ${EXPECTED_SHA256}"
