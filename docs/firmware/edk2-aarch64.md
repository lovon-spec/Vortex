# AArch64 EDK2 Firmware Trust Chain

Vortex bundles a QEMU ArmVirt AArch64 EDK2 pflash code image for native Linux
UEFI boot. The default path is internal to `Vortex.app`; custom firmware remains
possible through explicit configuration or `VORTEX_AARCH64_UEFI`, but Vortex no
longer auto-discovers Homebrew or UTM firmware as a default.

## Runtime Contract

- Bundled firmware reference: `vortex-bundled://Firmware/edk2-aarch64-code.fd`
- Bundle location: `Vortex.app/Contents/Resources/Firmware/edk2-aarch64-code.fd`
- Expected size: `67108864`
- Expected SHA-256: `47765fe344818cbc464b1c14ae658fb4b854f5c2ceffa982411731eb4865594d`

Vortex validates the size and SHA-256 before loading the bundled firmware. The
app packaging scripts also verify `SHA256SUMS` after copying the firmware into
the app bundle.

## Pinned Inputs

- Upstream EDK2 repository: `https://github.com/tianocore/edk2.git`
- Upstream EDK2 commit: `4dfdca63a93497203f197ec98ba20e2327e4afe4`
- Nearest stable EDK2 tag: `edk2-stable202408`
- QEMU build recipe tag: `v10.2.2`
- QEMU build recipe commit: `f8ed81651e61d9c2166df6121ce2af0f44f06b3e`
- Build container: `ghcr.io/tianocore/containers/ubuntu-22-build@sha256:bcda96cb0b9a39a881122ab7d3be86e6151f4c66968421827384c97850c790a5`

Submodule gitlinks are recorded in
`Sources/VortexGUI/Resources/Firmware/edk2-aarch64-code.fd.provenance.json` and
asserted by `scripts/firmware/build-edk2-aarch64.sh`.

## Verification Commands

Verify the checked-in firmware resource:

```sh
scripts/firmware/verify-bundled-firmware.sh
```

Verify the checked-in firmware against the pinned QEMU release blob:

```sh
scripts/firmware/verify-qemu-source-blob.sh
```

Rebuild ArmVirtQemu-AARCH64 from pinned sources in the pinned container:

```sh
scripts/firmware/build-edk2-aarch64.sh
```

Install the rebuilt artifact only after it matches the recorded SHA-256:

```sh
scripts/firmware/build-edk2-aarch64.sh --install
```

The source-build script requires Docker or Podman. It refuses to replace the
bundled firmware unless the rebuilt pflash image has the recorded size and
SHA-256.
