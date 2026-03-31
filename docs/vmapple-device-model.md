# vmapple Device Model: Comprehensive Technical Analysis

**Date:** 2026-03-31
**Track:** C (Strategic Long-Term Bet)
**Status:** Research Complete, Implementation Pending Entitlement Access

---

## Executive Summary

The vmapple device model is Apple's proprietary virtual hardware platform for running
macOS guests on Apple Silicon. It is presented by Virtualization.framework (VZ) to
guest macOS, gated behind the private entitlement `com.apple.private.hypervisor.vmapple`.
Every tool that runs macOS guests today -- Parallels, UTM/Tart, macosvm -- delegates to
VZ for macOS guests; none implement the vmapple device model independently.

QEMU's `hw/vmapple/` directory (merged in QEMU 10.0, authored by Alexander Graf at
Amazon) is the only known independent reimplementation. It successfully boots macOS 12.x
guests. This document reverse-engineers the vmapple device model primarily from QEMU's
implementation, the VMA2MACOSAP device tree, vma2pwn research, and VZ framework
reversing.

---

## 1. Platform Identity

The vmapple platform presents itself to macOS as:

| Property | Value |
|---|---|
| Model Identifier | `VirtualMac2,1` |
| Board Config | `VMA2MACOSAP` |
| Target Type | `VMA2MACOS` |
| Compatible Strings | `VMA2MACOSAP`, `VirtualMac2,1`, `AppleVirtualPlatformARM` |
| Product Name | `Apple Virtual Machine 1` |
| Manufacturer | `Apple Inc.` |
| CPID | `0xFE00` (virtual machine chip identifier) |
| Board ID (BDID) | `0x20` (platform version 2); `0xF8` (platform version 1) |
| CPFM | `0x03` (production) or `0x01` (demoted) |
| Platform Name | `vma2` |

The XNU kernel matches `AppleVirtualPlatformARM` as the IOPlatformExpert class. IOKit
personality matching uses these compatible strings to load the correct kexts, including
`AppleVirtIO.kext` (which contains drivers for virtio-blk, virtio-net, virtio-console,
virtio-9p, virtio-snd, and the PCI transport).

---

## 2. Memory Map

Derived from QEMU's `hw/vmapple/vmapple.c` memory map table:

| Region | Base Address | Size | Description |
|---|---|---|---|
| Firmware | `0x0010_0000` | 1 MB | AVPBooter firmware image |
| Config Device | `0x0040_0000` | 64 KB | Machine configuration MMIO |
| GIC Distributor | `0x1000_0000` | 64 KB | GICv3 Distributor |
| GIC Redistributor | `0x1001_0000` | 4 MB | GICv3 Redistributor (per-CPU) |
| UART (PL011) | `0x2001_0000` | 64 KB | Serial console |
| RTC (PL031) | `0x2005_0000` | 4 KB | Real-time clock |
| GPIO (PL061) | `0x2006_0000` | 4 KB | Buttons (power, etc.) |
| PvPanic | `0x2007_0000` | 2 bytes | Panic notification device |
| BDIF (Backdoor) | `0x3000_0000` | 2 MB | Backdoor block interface |
| APV Graphics | `0x3020_0000` | 64 KB | ParavirtualizedGraphics GPU |
| APV IOSFC | `0x3021_0000` | 64 KB | IOSurface mapper device |
| AES Engine 1 | `0x3022_0000` | 16 KB | Crypto engine (primary) |
| AES Engine 2 | `0x3023_0000` | 16 KB | Crypto engine (secondary) |
| PCIe ECAM | `0x4000_0000` | 256 MB | PCI configuration space |
| PCIe MMIO | `0x5000_0000` | ~512 MB | PCI 32-bit MMIO window |
| Guest RAM | `0x7000_0000` | Variable | Main memory (default 1 GB) |

**Key difference from Vortex Linux layout:** The vmapple memory map places RAM at
`0x7000_0000` (same as VZ Linux guests), firmware at `0x0010_0000`, and config at
`0x0040_0000`. The Vortex Linux layout uses `0x4000_0000` for RAM. These are
incompatible and would require a separate `MachineConfig` profile for vmapple.

---

## 3. Interrupt Map

| Device | SPI Number | Type |
|---|---|---|
| UART | 1 | Level |
| RTC | 2 | Level |
| GPIO (Buttons) | 5 | Level |
| IOSFC (IOSurface) | 16 (0x10) | Level |
| GPU (apple-gfx) | 17 (0x11) | Level |
| AES Engine | 18 (0x12) | Level |
| PCIe (base) | 32 (0x20) | Level |
| PCIe (IRQ 1-15) | 33-47 | Level |

GIC is configured with 256 external interrupt lines + 32 internal, supporting up to
32 vCPUs. Virtual timer is PPI 27.

---

## 4. Boot Chain

### 4.1 Three-Stage Architecture

```
Stage 0: AVPBooter.vmapple2.bin  (host-resident, provided by VZ framework)
     |
     v
Stage 1: LLB.img4 / iBSS        (in AuxiliaryStorage, img4 format)
     |
     v
Stage 2: iBoot.img4 / iBEC       (on guest filesystem)
     |
     v
XNU Kernel + kernelcache
```

**Critical detail:** All three stages are UNENCRYPTED in VMs (unlike bare metal where
the SEP holds decryption keys). This makes reverse engineering feasible.

### 4.2 AVPBooter

- Location: `/System/Library/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin`
- Loaded at `0x0010_0000` (firmware region)
- Validates img4 signatures of subsequent boot stages
- Can be patched: replace `image4_validate_property_callback()` with `MOV X0, #0x0; RET`
  to bypass signature checks

### 4.3 Boot Configuration

AVPBooter reads the Config Device (at `0x0040_0000`) to determine:
- Number of CPUs
- RAM size
- ECID (unique device identifier)
- Whether to run installer mode
- MAC addresses for network interfaces
- Serial number and hardware model

### 4.4 img4 Boot Object Tags

| Tag | Object |
|---|---|
| `illb` | LLB (Low-Level Bootloader) |
| `ibot` | iBoot |
| `krnl` | Kernel |
| `auxk` | Auxiliary kernel cache |

---

## 5. Device Specifications

### 5.1 Configuration Device (cfg)

**Type:** MMIO flat register space
**Base:** `0x0040_0000`
**Size:** 64 KB (`0x10000`)
**Complexity:** Low (pure data, no state machine)

The cfg device is a read-only memory region containing a fixed-layout structure that
AVPBooter and iBoot read during early boot. It is populated by the VMM before starting
the first vCPU.

#### Register Map (VMAppleCfg structure)

| Offset | Field | Type | Description |
|---|---|---|---|
| `0x000` | `version` | uint32 | Config format version (currently 2) |
| `0x004` | `nr_cpus` | uint32 | Number of configured vCPUs |
| `0x008` | `unk1` | uint32 | Unknown (set to 0) |
| `0x00C` | `unk2` | uint32 | Unknown (set to 0) |
| `0x010` | `unk3` | uint32 | Unknown (set to 0) |
| `0x014` | `unk4` | uint32 | Unknown (set to 0) |
| `0x018` | `ecid` | uint64 | Exclusive Chip ID (unique per VM) |
| `0x020` | `ram_size` | uint64 | RAM capacity in bytes |
| `0x028` | `run_installer1` | uint32 | Installer flag (1 = install mode) |
| `0x02C` | `unk5` | uint32 | Unknown |
| `0x030` | `unk6` | uint32 | Unknown |
| `0x034` | `run_installer2` | uint32 | Installer flag (duplicate) |
| `0x038` | `rnd` | uint32 | Random seed value |
| `0x03C` | `unk7` | uint32 | Unknown |
| `0x040` | `mac_en0` | 6 bytes | Ethernet 0 MAC address |
| `0x048` | `mac_en1` | 6 bytes | Ethernet 1 MAC address |
| `0x050` | `mac_wifi0` | 6 bytes | WiFi MAC address |
| `0x058` | `mac_bt0` | 6 bytes | Bluetooth MAC address |
| `0x060` | (reserved) | 160 bytes | Padding to 0x100 |
| `0x100` | `cpu_ids[128]` | uint32[] | Per-CPU identifiers (512 bytes) |
| `0x300` | `scratch` | 512 bytes | Scratch buffer |
| `0x380` | `serial` | char[32] | Device serial number |
| `0x3A0` | `unk8` | char[32] | Unknown string (hardcoded "D/A") |
| `0x3C0` | `model` | char[32] | Hardware model (e.g., "VM0001") |
| `0x3E0` | `unk9` | 32 bytes | Unknown |
| `0x400` | `unk10` | uint32 | Unknown (set to 1) |
| `0x404` | `soc_name` | char[32] | SoC identifier (e.g., "Apple M1 (Virtual)") |

**Implementation notes:**
- On reset, the entire region is zeroed then populated from VMM configuration.
- The `ecid` must match the value embedded in the AuxiliaryStorage; mismatches cause
  AVPBooter to refuse boot.
- The `serial` and `model` fields affect how macOS identifies the machine
  (System Information, DEP enrollment).

**Vortex implementation estimate:** ~100 lines Swift. Simple MMIO region that returns
pre-filled bytes. No complex state.

---

### 5.2 Backdoor Interface (BDIF)

**Type:** MMIO with DMA
**Base:** `0x3000_0000`
**Size:** 2 MB (`0x200000`)
**Complexity:** Medium (DMA block I/O, two device targets)

The BDIF provides early boot block device access before PCI/virtio is initialized.
AVPBooter uses it to read the auxiliary storage and root volume during the firmware
stage, before any drivers are loaded.

#### Register Map

| Offset | Name | R/W | Value/Description |
|---|---|---|---|
| `0x000` | `REG_STATUS` | R | Returns `0x1` (device active) |
| `0x004` | `REG_CFG` | R | Returns `0x2` (configured) |
| `0x008` | `REG_UNK1` | R | Returns `0x420` |
| `0x010` | `REG_BUSY` | R | Returns `0x1` (ready) |
| `0x400` | `REG_UNK2` | R | Returns `0x1` |
| `0x408` | `REG_CMD` | W | Command trigger (initiates DMA) |
| `0x420` | `REG_NEXT_DEVICE` | R | Next device address info |
| `0x434` | `REG_UNK3` | R | Returns `0x0` |

#### Device ID Masking

Register offsets are ORed with a device ID. The mask `0xFFFF0000` selects the device:

| Device ID | Mask | Size Returned | Description |
|---|---|---|---|
| `DEVID_ROOT` | `0x0000_0000` | `0x800_0000` (128 MB) | Root disk |
| `DEVID_AUX` | `0x0001_0000` | `0x1_0000` (64 KB) | Auxiliary storage |
| `DEVID_USB` | `0x0010_0000` | (unused) | Reserved for USB |

So to read the AUX device status, firmware reads from `0x3001_0000` (base + AUX mask + REG_STATUS).

#### DMA Command Protocol

Writing to `REG_CMD` triggers a DMA block read. The command reads a `VblkReq` structure
from guest memory:

```
VblkReq (24 bytes):
  +0x00: VblkSector { addr: uint64, len: uint64, flags: uint64 }  // sector metadata
  +0x18: data { addr: uint64, len: uint64, flags: uint64 }        // payload buffer
  +0x30: retval { addr: uint64 }                                   // completion status
```

```
VblkSector (16 bytes):
  +0x00: sector_number (uint32, little-endian)
  // Sector is multiplied by 512 to get byte offset
```

**Operations:**
| Flag Value | Operation | Notes |
|---|---|---|
| `0x0003_0001` | Read | Reads up to 128 MB from device at sector offset |
| `0x0001_0001` | Write | Defined but UNIMPLEMENTED ("iBoot only reads") |

**Return values:** 0 = success, 1 = failure (written to retval address via DMA).

**Vortex implementation estimate:** ~200 lines Swift. Needs MMIO handler + DMA read
from BlockBackend. Moderate complexity due to device ID multiplexing and DMA.

---

### 5.3 AES Crypto Engine

**Type:** MMIO with FIFO command interface and DMA
**Base:** `0x3022_0000` (engine 1), `0x3023_0000` (engine 2)
**Size:** 16 KB each (`0x4000`)
**Device Tree Compatible:** `aes,s8000`
**Complexity:** High (state machine, multiple crypto modes, DMA)

The virtual AES engine provides hardware-accelerated encryption for APFS volume
encryption and Data Protection. On bare metal, this is part of the Secure Enclave / disk
controller. In VMs, it is emulated to support the same APFS encryption that macOS expects.

Two AES engine instances are created (matching physical Apple Silicon which has separate
engines for different security domains).

#### Register Map

| Offset | Name | Width | Description |
|---|---|---|---|
| `0x00C` | `REG_STATUS` | 32-bit | Device status flags |
| `0x018` | `REG_IRQ_STATUS` | 32-bit | Interrupt status |
| `0x01C` | `REG_IRQ_ENABLE` | 32-bit | Interrupt enable mask |
| `0x020` | `REG_WATERMARK` | 32-bit | FIFO watermark threshold |
| `0x024` | `REG_Q_STATUS` | 32-bit | Queue status |
| `0x030` | `REG_FLAG_INFO` | 32-bit | Flag information |
| `0x200` | `REG_FIFO` | 32-bit | Command/data FIFO input |

#### Status Register Bits (offset 0x0C)

| Bit | Meaning |
|---|---|
| 0 | DMA read running |
| 1 | DMA read pending |
| 2 | DMA write running |
| 3 | DMA write pending |
| 4 | Device busy |
| 5 | Command executing |
| 6 | Device ready |
| 7 | Text DPA seeded |
| 8 | Unwrap DPA seeded |

#### Command Codes (4-bit field at bits [31:28] of FIFO word)

| Code | Name | Description |
|---|---|---|
| `0x1` | `CMD_KEY` | Load encryption key |
| `0x2` | `CMD_IV` | Load initialization vector |
| `0x3` | `CMD_DSB` | Data stream barrier |
| `0x4` | `CMD_SKG` | Secure key generation |
| `0x5` | `CMD_DATA` | Encrypt/decrypt data block |
| `0x6` | `CMD_STORE_IV` | Store IV to memory |
| `0x7` | `CMD_WRITE_REG` | Write internal register |
| `0x8` | `CMD_FLAG` | Set flags, optionally raise IRQ |

#### CMD_KEY (0x1) Detail

```
Bits [27]:    Context select (0 or 1)
Bits [26:24]: Key selection index (0-7, index into builtin key table)
Bits [23:22]: Key length:
              0 = AES-128 (16 bytes)
              1 = AES-192 (24 bytes)
              2 = AES-256 (32 bytes)
              3 = AES-512 (64 bytes)
Bit  [20]:    Direction: 1 = encrypt, 0 = decrypt
Bits [17:16]: Block mode:
              0 = ECB
              1 = CBC
Payload: Key data as sequence of 32-bit FIFO writes
```

#### CMD_DATA (0x5) Detail

```
Bit  [27]:    Key context selector
Bits [26:25]: IV context selector
Bits [23:0]:  Data length in bytes (max 16 MB)
FIFO[1]: High address bits (bits 47:32 for source and dest)
FIFO[2]: Source address (bits 31:0)
FIFO[3]: Destination address (bits 31:0)
```

DMA reads plaintext from source, encrypts/decrypts, writes result to destination.
Address space is 48-bit physical.

#### Key Storage

- 2 key contexts (indexed 0-1)
- 8 builtin key slots (indices 0-7), with keys at indices 1, 2, 3 pre-initialized
- Max key size: 256-bit (32 bytes)
- 4 IV contexts (128-bit each)
- FIFO depth: 9 entries (32-bit words)

**Is it required for boot?** Yes. macOS expects APFS volumes to use hardware encryption.
The AES engine must be present and functional for the volume to be mounted. Without it,
XNU cannot read the system volume.

**Vortex implementation estimate:** ~500 lines Swift. Significant complexity: FIFO-based
command processor, AES-CBC/ECB crypto operations (can delegate to CommonCrypto/CryptoKit),
DMA engine, interrupt generation. This is one of the harder devices.

---

### 5.4 vmapple Virtio Block Device

**Type:** PCI (virtio transport)
**Vendor ID:** `0x106B` (Apple)
**Device ID:** `0x1A00` (`PCI_DEVICE_ID_APPLE_VIRTIO_BLK`)
**PCI Class:** `PCI_CLASS_STORAGE_SCSI`
**Complexity:** Medium (extends existing virtio-blk)

This is NOT standard virtio-blk (vendor `0x1AF4`, device `0x1042`). macOS's
`AppleVirtIOBlock` driver matches on Apple's vendor/device IDs and expects
Apple-specific extensions.

#### Differences from Standard Virtio-BLK

1. **PCI Identity**: Vendor `0x106B` (Apple) instead of `0x1AF4` (Red Hat).
   Device ID `0x1A00` instead of `0x1042`.

2. **Apple Type Field**: The `max_secure_erase_sectors` field in the virtio-blk config
   space (a field reserved for zoned storage) is repurposed to carry an "apple type"
   identifier:
   - `VIRTIO_APPLE_TYPE_ROOT = 1` -- root volume
   - `VIRTIO_APPLE_TYPE_AUX = 2` -- auxiliary boot data
   This tells the guest driver which volume role the device serves.

3. **Apple Barrier Command**: A new request type `VIRTIO_BLK_T_APPLE_BARRIER = 0x10000`
   is supported. Currently treated as a no-op (returns `VIRTIO_BLK_S_OK`). Likely
   intended for write ordering guarantees.

4. **Feature Negotiation**: Requires `VIRTIO_BLK_F_ZONED` feature flag to be negotiated
   so the config space is large enough to include the apple type field at the
   `max_secure_erase_sectors` offset.

#### Variant Configuration

Two instances are created in the vmapple machine:
- `vmapple-virtio-blk-pci` with `variant=aux` -- auxiliary storage (boot metadata)
- `vmapple-virtio-blk-pci` with `variant=root` -- root disk (macOS system volume)

The aux volume is also passed as pflash (for BDIF early boot access), and as a
virtio-blk device (for OS-level access after drivers load).

**Vortex implementation estimate:** ~150 lines Swift on top of existing virtio-blk.
Need to change PCI IDs, add apple-type config field, handle barrier command. Moderate.

---

### 5.5 ParavirtualizedGraphics (apple-gfx)

**Type:** MMIO (for arm64 macOS guests; PCI variant exists for x86_64)
**GPU MMIO Base:** `0x3020_0000`
**GPU MMIO Size:** Dynamic (queried from `PGDeviceDescriptor.mmioLength`)
**IOSFC MMIO Base:** `0x3021_0000`
**IOSFC MMIO Size:** 64 KB (`0x10000`)
**Device Tree Compatible:** `paravirtualizedgraphics,gpu` (GPU), `paravirtualizedgraphics,iosurface` (IOSFC)
**Complexity:** Very High (depends on Apple's private framework)

#### Architecture

The apple-gfx device is a passthrough to Apple's `ParavirtualizedGraphics.framework`
(PVG). The VMM does NOT implement GPU emulation -- it acts as a shim:

1. VMM creates a `PGDeviceDescriptor` with a Metal device
2. VMM registers callbacks for memory mapping, interrupt delivery
3. Guest writes to MMIO -> VMM forwards to `PGDevice.mmioWriteAtOffset()`
4. Guest reads from MMIO <- VMM forwards from `PGDevice.mmioReadAtOffset()`
5. PVG framework raises interrupt -> VMM injects into guest GIC
6. PVG framework requests memory mapping -> VMM maps guest physical memory

#### Two MMIO Regions

| Region | Role | Size |
|---|---|---|
| GFX | GPU command interface | ~`desc.mmioLength` bytes (dynamic, ~4 KB typical) |
| IOSFC | IOSurface mapper for shared memory | 64 KB fixed |

The IOSFC region handles IOSurface sharing between host GPU and guest, using
`PGIOSurfaceHostDevice` with `mmioReadAtOffset` / `mmioWriteAtOffset` methods.

#### Framework API (Objective-C / Swift)

```
PGDeviceDescriptor:
  .device: MTLDevice              // Metal GPU to use
  .mmioLength: UInt               // Size of MMIO region
  .usingIOSurfaceMapper: Bool     // Enable IOSFC mode (true for MMIO variant)

PGDevice:
  mmioReadAtOffset(_:) -> UInt64
  mmioWriteAtOffset(_:value:)

PGDisplay:
  name: String
  sizeInMillimeters: CGSize
  newFrameEventHandler: Block
  modeChangeHandler: Block
  cursorGlyphHandler: Block
  cursorShowHandler: Block
  cursorMoveHandler: Block

PGIOSurfaceHostDeviceDescriptor:
  .mapMemory: (phys, len, ro, va_out, ...) -> Void
  .unmapMemory: (va, len, ...) -> Void
  .raiseInterrupt: (vector) -> Void
```

#### macOS 15.4+ Changes

Newer macOS versions switched from callback-based memory management to a descriptor-based
approach using `PGMemoryMapDescriptor`:
- VMM iterates guest physical address space via `flatview_for_each_range()`
- Registers ranges via `addRange:` with physical address, length, host pointer
- Enables `enableProcessIsolation` for sandboxed GPU process
- Sets `mmioLength = 0x10000` on IOSFC device

#### Can It Be Replicated Without PVG Framework?

**No.** The PVG framework implements a proprietary protocol between a guest-side GPU
driver (`AppleParavirtGPU.kext`) and the host-side Metal stack. The protocol is
undocumented, uses shared memory for command buffers, and changes between macOS versions.
Reimplementing it would require reverse-engineering the entire GPU command stream, which
is infeasible.

**The PVG framework IS public** (available in macOS SDK), so any VMM can use it. The
constraint is that the guest must also have the matching `AppleParavirtGPU.kext`, which
is only present in vmapple macOS guests.

**Vortex implementation estimate:** ~300 lines Swift for the shim layer, but fundamentally
depends on `ParavirtualizedGraphics.framework`. The MMIO forwarding is straightforward;
the complexity is in memory mapping callbacks and ensuring RT-safe interrupt delivery.

---

### 5.6 PvPanic Device

**Type:** MMIO
**Base:** `0x2007_0000`
**Size:** 2 bytes
**Device Tree Compatible:** `qemu,pvpanic-mmio`
**Complexity:** Trivial

Guest writes to this address to signal a kernel panic to the VMM. Single register,
write-only. The VMM can use this to trigger crash logging or VM restart.

**Vortex implementation estimate:** ~20 lines Swift.

---

### 5.7 Standard ARM Peripherals

These are identical to the Vortex Linux machine layout (just different addresses):

| Device | Compatible | vmapple Address | Notes |
|---|---|---|---|
| PL011 UART | `arm,pl011` | `0x2001_0000` | Serial console |
| PL031 RTC | `ARM,pl031` | `0x2005_0000` | Real-time clock |
| PL061 GPIO | `ARM,pl061` | `0x2006_0000` | Buttons: pin 3 = power |
| GICv3 | `gic,vmapple1` / `ARM,gicv3` | `0x1000_0000` | Interrupt controller |

The GIC compatible string includes `gic,vmapple1` in addition to the standard ARM string.

---

### 5.8 PCIe Host Bridge

**Type:** GPEX (Generic PCI Express)
**ECAM Base:** `0x4000_0000`
**ECAM Size:** 256 MB
**MMIO Window:** `0x5000_0000` - `0x6FFF_0000` (~512 MB, 32-bit)
**Device Tree Compatible:** `pcie,vmapple1`
**IRQs:** 16 lines starting at SPI 32

The PCIe bus hosts:
- 2x vmapple-virtio-blk-pci (aux + root)
- 1x virtio-net-pci (standard virtio network)
- 1x QEMU XHCI USB controller (for keyboard/mouse)

**macOS XHCI quirk:** macOS's XHCI driver expects MSI-X to be available. When only
pin-based interrupts are available, the driver incorrectly tries to use event ring
interrupters 1 and 2. QEMU had to implement workarounds for this.

---

### 5.9 xHCI USB Controller

**Type:** PCI
**Complexity:** High (full xHCI spec, but can reuse existing implementations)

The xHCI controller provides USB keyboard, mouse/tablet, and potentially mass storage.
On vmapple, it sits on the PCIe bus. macOS includes built-in xHCI drivers.

**Note on input:** The vmapple machine uses USB HID for keyboard/mouse input, NOT
virtio-input. This is because macOS's vmapple guest does not include virtio-input drivers.

---

### 5.10 Virtio Sound (virtio-snd)

**Type:** PCI (standard virtio-snd, `0x1AF4:0x1059`)
**Not vmapple-specific** -- uses standard virtio-snd PCI transport
**Device Tree role:** Standard virtio device on PCIe bus

macOS includes `AppleVirtIOSound.kext` in `AppleVirtIO.kext` which matches standard
virtio-snd devices. This is the audio device for vmapple macOS guests. VZ creates it
as a standard virtio device, not an Apple-modified one.

**This is directly relevant to Vortex's audio architecture.** If we implement the
vmapple device model, we can use our standard virtio-snd implementation for audio,
maintaining our per-VM audio routing via the host-side CoreAudio AudioUnit path.

---

## 6. Device Tree Structure

The vmapple device tree (Apple Device Tree format, NOT FDT/DTB) extracted from
`DeviceTree.vma2macosap.im4p` contains:

### 6.1 Root Properties

```
compatible = "VMA2MACOSAP", "VirtualMac2,1", "AppleVirtualPlatformARM"
model = "VirtualMac2,1"
manufacturer = "Apple Inc."
product-name = "Apple Virtual Machine 1"
target-type = "VMA2MACOS"
board-config = "VMA2MACOSAP"
vmm-present = 1
```

### 6.2 CPU Nodes

Eight ARM v8 cores:
```
cpus/
  cpu0: state=running, phandle=17
  cpu1: state=waiting, phandle=18
  ...
  cpu7: state=waiting, phandle=24
```

### 6.3 arm-io Subsystem

```
arm-io/
  compatible = "arm-io,vmapple1"
  device-type = "vmapple1-io"

  aes/          compatible="aes,s8000"         (AES engine v3)
  uart0/        (serial port)
  gic/          compatible="gic,vmapple1", "ARM,gicv3"
  rtc/          compatible="ARM,pl031"
  buttons/      compatible="ARM,pl061"         role="VMA1_BUTTONS"
  pvpanic/      compatible="qemu,pvpanic-mmio"
  pcie/         compatible="pcie,vmapple1"
  iosurface/    compatible="paravirtualizedgraphics,iosurface"  role="APV_IOSFC"
  gpu/          compatible="paravirtualizedgraphics,gpu"        role="APV_GFX"
```

### 6.4 Chosen Node (Security Configuration)

```
chosen/
  crypto-hash-method = "sha2-384"
  allow-non-apple-code = 1
  protected-data-access = 1
  sep-firmware-load = 1
  allowed-boot-args = "trace, trace_wake, kperf, -x"
```

### 6.5 Filesystem Mounts

```
filesystems/
  fstab/
    system:    mount="/"                    options="ro"
    preboot:   mount="/private/preboot"     options="ro"
    data:      mount="/private/var"         options="rw"
    update:    mount="/private/var/MobileSoftwareUpdate" options="rw"
    hardware:  mount="/private/var/hardware" options="rw"
```

### 6.6 Product Properties

```
product/
  device-class = 16 (memory)
  graphics-featureset = "APPLE7"
  dual-iboot = 1
  single-stage-boot = 1
  artwork-device-idiom = "mac"
  allow-32bit-apps = 1
```

---

## 7. The vmapple Entitlement

### 7.1 What It Is

`com.apple.private.hypervisor.vmapple` is a private entitlement held by the VZ XPC
service binary at:
```
/System/Library/Frameworks/Virtualization.framework/XPCServices/
  com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/
  com.apple.Virtualization.VirtualMachine
```

Full entitlement list of this binary:
- `com.apple.security.hypervisor` (public)
- `com.apple.private.hypervisor.vmapple` (private)
- `com.apple.vm.networking`
- `com.apple.usb.hostcontrollerinterface`
- `com.apple.private.security.message-filter`

### 7.2 What It Enables

The entitlement gates the vmapple device model in Hypervisor.framework. Based on
analysis, it likely enables:

1. **Authorization gate for `hv_vm_create()`** with vmapple configuration -- the kernel
   checks the calling process has this entitlement before allowing VM creation with
   Apple-specific features.

2. **Possible access to additional system registers** that are restricted without the
   entitlement (e.g., registers related to Apple's virtual platform identity).

3. **Not a device emulation enabler** -- the entitlement does not cause HV.framework to
   magically create vmapple devices. Device emulation is done in userspace (by the VZ
   XPC service, or by QEMU). The entitlement just unlocks the ability to create a VM
   that can present the vmapple identity.

### 7.3 Workaround

Boot with `amfi_get_out_of_my_way=1` boot argument to disable AMFI (Apple Mobile File
Integrity), allowing self-signed binaries with arbitrary entitlements. **Not viable for
production.** Requires SIP disabled and is development-only.

### 7.4 Can It Be Obtained?

**Current assessment: No established path for third parties.**

- **Parallels Desktop** does NOT have the vmapple entitlement. Parallels uses
  Virtualization.framework for macOS guests, which means the entitlement is held by
  Apple's own VZ XPC service, not by Parallels' binary. For non-macOS guests, Parallels
  uses Hypervisor.framework with its own VMM.

- **Apple Developer Forums** show no formal process for requesting private HV
  entitlements. The `com.apple.vm.networking` entitlement (also restricted) can be
  requested through Apple Developer relations, but `vmapple` has not been mentioned.

- **Enterprise/Partner Programs** -- Apple has worked closely with Parallels (confirmed
  by KB articles stating they "work closely with Apple"), but this appears to be a
  business relationship for VZ framework features, not private entitlement grants.

- **The VZ XPC architecture means third parties never need the entitlement directly** --
  when apps use Virtualization.framework, it is Apple's own XPC service (signed by Apple,
  with Apple's entitlements) that talks to Hypervisor.framework. The calling app only
  needs `com.apple.security.virtualization`.

**Bottom line:** There is no known path to obtaining `com.apple.private.hypervisor.vmapple`
for a standalone VMM. The only legitimate way to run macOS guests is through
Virtualization.framework, which is Apple's deliberate architectural choice.

---

## 8. Implementation Complexity Summary

| Device | Lines Est. | Complexity | Required for Boot | Dependencies |
|---|---|---|---|---|
| Config (cfg) | ~100 | Low | Yes (Stage 0) | None |
| BDIF (backdoor) | ~200 | Medium | Yes (Stage 0-1) | BlockBackend, DMA |
| AES Engine (x2) | ~500 | High | Yes (volume mount) | CryptoKit, DMA |
| Virtio-BLK (Apple) | ~150 | Medium | Yes (OS-level disk) | VirtIO PCI base |
| apple-gfx (GPU) | ~300 | Medium* | Yes (display) | PVG.framework |
| PvPanic | ~20 | Trivial | No | None |
| PL011 UART | (existing) | -- | No (but useful) | -- |
| PL031 RTC | (existing) | -- | No | -- |
| PL061 GPIO | (existing) | -- | Maybe (power btn) | -- |
| GICv3 | (existing) | -- | Yes | -- |
| PCIe Host | (existing) | -- | Yes | -- |
| xHCI USB | ~1000+ | Very High | Yes (input) | USB stack |
| virtio-snd | (existing) | -- | No (but needed) | -- |
| virtio-net | (existing) | -- | No | -- |

*apple-gfx complexity is "Medium" because it is a shim to PVG.framework, but the
framework itself is opaque and its requirements change between macOS versions.

**Total estimated new code:** ~2,300 lines for vmapple-specific devices, assuming
existing Vortex infrastructure for virtio, PCI, GIC, UART, RTC.

---

## 9. Strategic Assessment

### 9.1 Technical Feasibility

Implementing the vmapple device model in Vortex is **technically feasible**. QEMU has
proven it can be done (~2,200 lines of C across the vmapple devices). The devices are
relatively simple MMIO state machines, with the AES engine being the most complex.

### 9.2 Entitlement Barrier

The `com.apple.private.hypervisor.vmapple` entitlement is the **sole blocking issue**.
Without it, a custom VMM cannot create a VM that presents the vmapple platform identity.
All the device emulation in the world is useless if the kernel refuses to let you create
the VM.

### 9.3 Recommended Path Forward

1. **Maintain the hybrid VZ + vsock architecture** as the production path for macOS
   guests. Use VZ for boot/lifecycle, tunnel audio over vsock for per-VM routing.

2. **Implement the vmapple devices speculatively** as Track C work. The code is
   ~2,300 lines and exercises our MMIO/DMA/PCI infrastructure. If the entitlement
   situation changes (Apple partner program, macOS policy change, development-only
   mode), we can activate it immediately.

3. **Priority implementation order:**
   - cfg device (trivial, unblocks understanding of boot flow)
   - BDIF (enables firmware boot testing)
   - AES engine (most complex, start early)
   - vmapple-virtio-blk (extends existing virtio-blk)
   - apple-gfx shim (depends on PVG framework integration)

4. **Monitor QEMU vmapple development** for compatibility changes. The QEMU
   implementation is actively maintained and tracks macOS version requirements.

### 9.4 Alternative: Development-Only Mode

For development and testing purposes, `amfi_get_out_of_my_way=1` allows self-signing
with the vmapple entitlement. This is useful for:
- Validating our vmapple device implementation
- Running automated tests on development machines
- Proving the architecture works end-to-end

This should NOT be the production deployment strategy.

---

## 10. Open Questions

1. **Audio in vmapple:** VZ uses standard virtio-snd for macOS guest audio. If we
   implement vmapple natively, can we use our virtio-snd with custom host-side routing?
   **Likely yes** -- the guest driver is standard.

2. **macOS version compatibility:** QEMU only supports macOS 12.x guests currently.
   Newer guests may require additional devices or protocol changes (e.g., the PVG
   changes for macOS 15.4+). What is the minimum macOS guest we need to support?

3. **AES builtin keys:** What are the pre-initialized key values at indices 1, 2, 3?
   Are they fixed constants or derived from the ECID? This needs reverse engineering
   of AVPBooter's AES usage.

4. **Auxiliary storage format:** The aux image contains img4-wrapped iBoot stages.
   What is the exact format? QEMU trims the first 16 KB -- what is in those bytes?

5. **Device tree delivery:** On bare metal, iBoot builds the device tree. In VZ, the
   device tree is pre-built (DeviceTree.vma2macosap.im4p). Does the VMM need to provide
   a complete device tree, or does AVPBooter build one from the cfg device?

---

## Sources

- [QEMU vmapple Documentation](https://www.qemu.org/docs/master/system/arm/vmapple.html)
- [QEMU vmapple Patch Series v1 (Graf)](https://patchew.org/QEMU/20230614224038.86148-1-graf@amazon.com/)
- [QEMU vmapple Patch Series v2](https://mail.gnu.org/archive/html/qemu-devel/2023-08/msg05751.html)
- [QEMU pci_ids.h (Apple/Virtio IDs)](https://github.com/qemu/qemu/blob/master/include/hw/pci/pci_ids.h)
- [DeviceTree.vma2macosap.im4p Dump](https://gist.github.com/blacktop/c480ec1eeb87767e714e054f78128c42)
- [VZ XPC Entitlements (woachk)](https://gist.github.com/woachk/30baddae2fd76adc75aa9db12496ddd4)
- [Virtual-iBoot-Fun (NyanSatan)](https://github.com/NyanSatan/Virtual-iBoot-Fun)
- [vma2pwn (nick-botticelli)](https://github.com/nick-botticelli/vma2pwn)
- [VZ Framework Reversing (kel.bz)](https://kel.bz/post/virtualization-framework-reversing/)
- [macOS Guest VM Kext Loading (steven-michaud)](https://gist.github.com/steven-michaud/fda019a4ae2df3a9295409053a53a65c)
- [Apple Silicon VM Limit Bypass (khronokernel)](https://khronokernel.com/macos/2023/08/08/AS-VM.html)
- [VZ Boot Analysis (Eclectic Light)](https://eclecticlight.co/2023/10/21/what-happens-when-you-run-a-macos-vm-on-apple-silicon/)
- [Parallels macOS VM Limitations](https://kb.parallels.com/128867)
- [ParavirtualizedGraphics.framework](https://developer.apple.com/documentation/paravirtualizedgraphics)
- [QEMU apple-gfx PCI Patch v14](https://mail.gnu.org/archive/html/qemu-devel/2024-12/msg03210.html)
- [QEMU vmapple virtio-blk Patch (PULL)](https://www.mail-archive.com/qemu-devel@nongnu.org/msg1099160.html)
- [QEMU apple-gfx macOS 15.4 Compatibility](https://www.mail-archive.com/qemu-devel@nongnu.org/msg1145031.html)
- [vma2 Boot Diagnostics Log](https://gist.github.com/nick-botticelli/5398b9c3dd7dc2b9101f6037f585f72f)
- [VirtualMac2,1 - Apple Wiki](https://theapplewiki.com/wiki/VirtualMac2,1)
