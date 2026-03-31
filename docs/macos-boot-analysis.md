# macOS Guest Boot Chain Analysis on Apple Silicon

**Phase 0 Feasibility Sprint -- Vortex VMM Project**
**Date:** 2026-03-31
**Status:** Research Complete

---

## Executive Summary

Booting a macOS guest inside a custom VMM built on Hypervisor.framework (without
Virtualization.framework) is **the single hardest problem in the Vortex project**
and carries significant feasibility risk. The macOS boot chain on Apple Silicon is
deeply tied to Apple's firmware, signing infrastructure, and proprietary device
model ("vmapple"). No public project has successfully booted a macOS guest on
Apple Silicon using raw Hypervisor.framework alone. Every tool that runs macOS
guests today (Parallels for macOS guests, Tart, UTM's macOS mode, VirtualBuddy)
ultimately delegates to Virtualization.framework's `VZMacOSBootLoader`.

This document lays out everything discovered about the boot chain, the vmapple
platform, the firmware pipeline, and the device tree -- then rates each approach
for feasibility.

---

## 1. IPSW Structure

An `.ipsw` file is a renamed ZIP archive. For macOS on Apple Silicon, it contains:

### 1.1 Top-Level Contents

| Path | Description |
|------|-------------|
| `BuildManifest.plist` | Component hashes (SHA-256), TSS signing metadata, device compatibility |
| `Restore.plist` | Restore-flow metadata, compatibility info |
| `Firmware/` | Boot chain firmware (iBoot stages, SEP, device trees, baseband) |
| `*.dmg` (root filesystem) | APFS disk image containing the OS root volume |
| `*.dmg` (update ramdisk) | RAM disk for update flow |
| `*.dmg` (restore ramdisk) | RAM disk for restore flow |
| `*.dmg` (recoveryOS) | Recovery environment (macOS/tvOS/audioOS) |
| `kernelcache.*` | Boot Kernel Collection in IMG4 container format |

### 1.2 Firmware Directory

| Component | Format | Encrypted? | Purpose |
|-----------|--------|------------|---------|
| `iBoot` (Stage 2) | IMG4 | AES-encrypted | OS-level bootloader |
| `LLB` (Stage 1) | IMG4 | AES-encrypted | Low-Level Bootloader |
| `iBSS` | IMG4 | AES-encrypted | DFU recovery bootstrap |
| `iBEC` | IMG4 | AES-encrypted | DFU recovery bootloader |
| `iBootData` | IMG4 | AES-encrypted | Boot data payload |
| `SEP firmware` | IMG4 | AES-encrypted | Secure Enclave Processor firmware |
| `DeviceTree` | IMG4 | Unencrypted | Hardware description for kernel |
| Firmware images | Various | Unencrypted | Apple logo, battery images, recovery screen |
| Baseband (`.bbfw`) | Renamed ZIP | Varies | Cellular baseband firmware |

### 1.3 Key Observations

- The **kernelcache** is unencrypted and can be extracted from the IPSW without keys.
  It is a Boot Kernel Collection (BKC) containing the XNU kernel and essential kexts,
  wrapped in IMG4 container format.
- The **firmware files** (iBoot, LLB, iBSS, iBEC, iBootData, SEP) are AES-encrypted
  with device-class keys. They cannot be used directly without decryption.
- The **DeviceTree** inside the IPSW describes physical hardware, not a VM -- it is
  not useful for VM boot. VMs get a different device tree constructed by the VMM.
- **BuildManifest.plist** is critical for TSS (Ticket Signing Server) interaction.
  It is sent to Apple's TSS server to obtain SHSH blobs for firmware personalization.
- IPSW files are universal across Apple Silicon Macs of compatible generations.

### 1.4 VM-Specific Firmware

For virtual machines, Apple uses a **different firmware chain** than physical hardware:

| Component | Location | Encrypted? |
|-----------|----------|------------|
| `AVPBooter.vmapple2.bin` (Stage 0) | `/System/Library/Frameworks/Virtualization.framework/Resources/` on host | **No** |
| `LLB.img4` (Stage 1) | Embedded in VM's `AuxiliaryStorage` file on host | **No** |
| `iBoot.img4` (Stage 2) | Guest filesystem (`/usr/standalone/firmware/`) | **No** |

**Critical finding:** For VMs, all three boot stage modules are **unencrypted**.
This is a meaningful difference from physical hardware.

---

## 2. VZ Boot Sequence (What Virtualization.framework Does Internally)

### 2.1 Architecture Overview

Virtualization.framework is a **high-level abstraction** that does NOT directly
call most Hypervisor.framework APIs in the client process. Instead:

1. The client process (your app) calls VZ APIs (e.g., `VZVirtualMachine.start()`).
2. VZ sends XPC messages to `com.apple.Virtualization.VirtualMachine.xpc`.
3. The XPC service (running in a sandboxed process) performs the actual VMM work.
4. The XPC service holds the private entitlements needed for macOS guest boot.

### 2.2 XPC Service Entitlements

The VZ XPC service has these entitlements (extracted from the binary):

| Entitlement | Purpose |
|-------------|---------|
| `com.apple.security.hypervisor` | Access to Hypervisor.framework APIs |
| `com.apple.private.hypervisor.vmapple` | **Private**: enables the vmapple device model in HV |
| `com.apple.vm.networking` | VM networking capabilities |
| `com.apple.usb.hostcontrollerinterface` | USB host controller passthrough |
| `com.apple.private.security.message-filter` | Security message filtering |

**Critical finding:** The `com.apple.private.hypervisor.vmapple` entitlement is
what unlocks the ability to boot macOS guests. This is a **private entitlement**
that third-party developers cannot obtain through normal channels. It likely
enables a special HV API mode that presents the vmapple device model to the guest.

### 2.3 macOS Guest Boot Sequence

Based on reverse engineering research (NyanSatan, steven-michaud, Nick Botticelli):

```
Host Process                    VZ XPC Service                    Guest VM
     |                                |                                |
     |-- VZMacOSInstaller.install() ->|                                |
     |                                |-- Download/validate IPSW ----->|
     |                                |-- Extract firmware components ->|
     |                                |-- Create AuxiliaryStorage ----->|
     |                                |   (embed LLB.img4 at 0x24000) |
     |                                |-- Write guest disk image ----->|
     |                                |                                |
     |-- VZVirtualMachine.start() --->|                                |
     |                                |-- hv_vm_create() ------------->|
     |                                |-- hv_vm_map() (memory) ------->|
     |                                |-- Load AVPBooter.vmapple2.bin ->|
     |                                |   into guest flash region      |
     |                                |-- Map AuxiliaryStorage ------->|
     |                                |-- hv_vcpu_create() ----------->|
     |                                |-- hv_vcpu_run() -------------->|
     |                                |                                |
     |                                |                    AVPBooter (Stage 0)
     |                                |                    - Validates LLB digest
     |                                |                    - Loads LLB from AuxStorage
     |                                |                          |
     |                                |                    LLB (Stage 1)
     |                                |                    - Validates iBoot digest
     |                                |                    - Loads iBoot from guest FS
     |                                |                          |
     |                                |                    iBoot (Stage 2)
     |                                |                    - Validates kernelcache digest
     |                                |                    - Builds device tree
     |                                |                    - Loads Boot Kernel Collection
     |                                |                    - Jumps to XNU kernel
     |                                |                          |
     |                                |                    XNU Kernel
     |                                |                    - Parses device tree
     |                                |                    - Initializes IOKit
     |                                |                    - Mounts root filesystem
     |                                |                    - Launches launchd
```

### 2.4 Digest Verification Chain

Each boot stage validates the next using IMG4 digest (DGST) verification:

- **AVPBooter (Stage 0)** checks the digest of the Stage 1 LLB img4 image
- **LLB (Stage 1)** checks the digest of the Stage 2 iBoot img4 file
- **iBoot (Stage 2)** checks the digest of the kernelcache file

These checks can be bypassed by patching: locating the `0x4447` (DGST) marker
and replacing the validation function's return register operation with
`mov x0, #0x0` (return success). See Section 5 for details.

### 2.5 Memory Layout (from VZ Device Tree)

Based on the extracted VZ Flatted Device Tree (FDT):

```
Address Range                    Component
0x0000_0000_1000_0000           GIC Distributor (64 KB)
0x0000_0000_1001_0000           GIC Redistributor (128 KB)
0x0000_0000_2005_0000           PL031 RTC (4 KB)
0x0000_0000_2006_0000           PL061 GPIO (4 KB)
0x0000_0000_2007_0000           pvpanic-mmio (2 bytes)
0x0000_0000_4000_0000           PCI ECAM config space (256 MB)
0x0000_0000_5000_0000           PCI 32-bit MMIO window (~503 MB)
0x0000_0000_6FFF_0000           PCI I/O window (64 KB)
0x0000_0000_7000_0000           Guest RAM base (variable size)
0x0000_0001_0000_0000           PCI 64-bit MMIO window (1 GB)
```

**Note:** This FDT was dumped from a Linux guest configuration. The macOS guest
configuration uses a different, proprietary device tree format (Apple Device Tree
/ ADT, not FDT) and a different memory layout.

### 2.6 Devices Presented to macOS Guests

Based on QEMU's vmapple reverse engineering and VZ analysis:

| Device | Type | Purpose |
|--------|------|---------|
| GICv3 | Interrupt controller | Standard ARM GIC |
| vmapple-virtio-blk-pci (aux) | Block storage | Auxiliary partition (firmware metadata) |
| vmapple-virtio-blk-pci (root) | Block storage | Root disk |
| virtio-net-pci | Network | Guest networking |
| XHCI USB controller | USB | USB device passthrough |
| apple-gfx-vmapple | Display | Paravirtualized GPU (ParavirtualizedGraphics.framework) |
| AES engine | Crypto | Hardware-accelerated AES |
| Configuration device (cfg) | Platform | Machine configuration |
| pvpanic variant | Debug | Guest panic notification |
| Backdoor interface (BDIF) | Platform | Host-guest communication channel |
| Virtio sound | Audio | Audio playback/capture (via VZVirtioSoundDeviceConfiguration) |

**Critical finding for Vortex:** VZ uses `VZVirtioSoundDeviceConfiguration` for
audio, which presents a standard Virtio sound device to the guest. The audio is
routed through CoreAudio on the host, but VZ does **not** expose an API to select
which CoreAudio device receives the audio. It always uses the system default.
This is the exact limitation that motivates Vortex's custom VMM approach.

---

## 3. Known Approaches and Prior Art

### 3.1 m1n1 (Asahi Linux)

**What it is:** The first-stage bootstrap for Apple Silicon, bridging between the
XNU boot protocol and the Linux ARM64 boot protocol.

**How it works:**
- Installed as a "custom kernel" in an APFS container (replacing XNU in the boot slot).
- iBoot2 loads m1n1 as if it were XNU.
- m1n1 parses the Apple Device Tree (ADT), performs hardware init, then chainloads
  Linux with a standard FDT.
- Supports embedded payloads: kernel images, FDT blobs, initramfs.
- Has a hypervisor mode for development/debugging.

**Relevance to Vortex:**
- m1n1 proves that iBoot can load non-XNU code on bare metal with Permissive Security.
- However, m1n1 operates **within** Apple's boot chain (loaded by iBoot), not outside it.
- m1n1 is for bare metal, not VMs. The VM boot chain is different.
- m1n1-xnu-boot forks exist that modify m1n1 to chainload XNU kernels, demonstrating
  that the XNU boot protocol can be implemented by third-party code.

### 3.2 m1n1-xnu-boot (jevinskie, jslegendre, Peterpan0927)

**What it is:** Modified m1n1 that boots XNU/macOS kernels on bare metal Apple Silicon.

**Key findings:**
- Demonstrates that XNU can be loaded by non-Apple bootloaders on bare metal.
- Requires Permissive Security on the host Mac.
- Works on bare metal only -- not tested/designed for VM contexts.
- Implies that if we can get control of the boot environment, XNU's boot protocol
  is implementable.

### 3.3 xnuqemu (worthdoingbadly / Zhuowei Zhang)

**What it is:** Boots iOS and macOS ARM64 kernels in QEMU, bypassing iBoot entirely.

**How it works:**
1. Extracts the kernelcache (Boot Kernel Collection) from an IPSW.
2. Constructs a minimal device tree with required nodes.
3. Creates a `boot_args` structure and places it in memory.
4. Points CPU register x0 at the boot_args structure.
5. Jumps directly to the kernel entry point.

**Key technical details:**
- Used an iPad Pro device tree from iOS 14 as a starting point.
- macOS requires additional DT nodes vs iOS: RAM size info, NVRAM node (prevents
  null pointer panic during nonce-seed reading), AMCC/KTRR register positions.
- Boot arguments used: `cs_enforcement_disable=1 amfi_get_out_of_my_way=1
  nvram-log=1 debug=0x8 cpus=1 rd=md0 apcie=0xffffffff`
- Had to disable PAC (Pointer Authentication) by making PAC instructions no-ops.
- **Result:** Kernel booted to launchd initialization. Serial port worked.
  "Absolutely nothing else is supported: literally only the kernel and the serial
  port works, not even the userspace since there's no disk driver."
- Half of drivers failed to load; no disk, no filesystem, no shell.

**Relevance to Vortex:**
- **This is the strongest existence proof** that XNU can be loaded without Apple's
  firmware, at least to early boot.
- However, getting to a functional userspace requires emulating the vmapple device
  model or providing equivalent drivers -- a massive undertaking.

### 3.4 QEMU VMApple Machine Type

**What it is:** QEMU implementation of the vmapple device model that Virtualization.framework
exposes to macOS guests.

**How it works:**
- Uses Apple's `AVPBooter.vmapple2.bin` as Stage 0 firmware.
- Requires a pre-installed macOS VM (created by VZ first).
- Emulates the vmapple-specific devices: custom virtio-blk extensions, apple-gfx,
  AES engine, BDIF, configuration device.
- Uses HVF accelerator on Apple Silicon.

**Limitations:**
- Only supports macOS 12 guests (13+ fail during early boot).
- Requires extracting UUID and auxiliary storage from a VZ-created VM.
- Cannot install macOS from scratch -- needs VZ to do the initial install.
- The vmapple device model is not fully documented; QEMU's implementation is
  reverse-engineered and incomplete.

**Key insight:** Even QEMU, with its massive codebase and years of development,
cannot boot macOS 13+ as a vmapple guest. The vmapple device model changes
between macOS versions and is not publicly documented.

### 3.5 NyanSatan's Virtual-iBoot-Fun

**What it is:** Objective-C project using Virtualization.framework to boot iBoot
in a VM with custom firmware.

**Key findings:**
- Requires `com.apple.private.virtualization` entitlement, which requires booting
  the host Mac with `amfi_get_out_of_my_way=1`.
- AVPBooter must be patched to bypass signature validation (replace
  `image4_validate_property_callback()` with a return-zero stub).
- Boot sequence: AVPBooter -> iBSS (via iRecovery) -> iBEC -> DeviceTree +
  ramdisk + trustcache + kernelcache.
- IMG4 manifests must come from TSS responses, not IPSW bundles.
- Achieved: booted to a patched kernel with GDB server and debug UART.
- Minimum 2 GB RAM (iBootStage1 panics below this).
- **Not updated since macOS 12.0.1** -- API changes in Ventura broke it.

### 3.6 vma2pwn (Nick Botticelli)

**What it is:** Scripts and patches to create a fully modifiable vma2 (virtual Mac
platform) boot chain for macOS guest VMs.

**Key findings:**
- Can patch AVPBooter, LLB, and iBoot to bypass all signature checks.
- TSS (Apple's signing server) **does sign firmware for the public vma2 device** --
  any firmware provided, in fact.
- Successfully used to create modified boot chains for iOS virtualization experiments.
- Led to `super-tart` (modified Tart fork) using undocumented VZ APIs including
  `_setProductionModeEnabled(false)` for chip fuse mode demotion.

### 3.7 Tart, UTM, VirtualBuddy

All three use **Virtualization.framework** for macOS guests:

- **Tart**: Pure VZ, CLI-focused, macOS + Linux guests. No custom VMM path.
- **UTM**: Uses QEMU for non-Apple guests, VZ for macOS guests on Apple Silicon.
  No custom VMM for macOS guests.
- **VirtualBuddy**: Pure VZ, GUI-focused. No custom VMM path.

**No public tool boots macOS guests without Virtualization.framework on Apple Silicon.**

### 3.8 Parallels Desktop

Parallels uses **Virtualization.framework for macOS guests** on Apple Silicon.
For Windows/Linux guests, it uses **Hypervisor.framework with its own VMM**. This
confirms that even a well-funded commercial vendor with deep Apple relationships
does not have an alternative path for macOS guest boot.

---

## 4. Apple Silicon VM Boot Chain

### 4.1 Physical Hardware Boot Chain

```
SecureROM (Boot ROM, in chip)
    |
    v
LLB / iBoot1 (Stage 1, from NOR flash)
    - Reads/validates system-global firmware from NOR
    - Bootstraps coprocessors (storage, display, SMC, Thunderbolt)
    - Shows Apple logo, plays boot chime
    - Picks and validates a boot policy (LocalPolicy from SEP)
    - Loads iBoot2 from NVMe
    |
    v
iBoot2 (Stage 2, from NVMe/OS partition)
    - Reads/validates OS-paired firmware from NVMe
    - Reads/validates the Apple Device Tree from NVMe
    - Reads/validates the OS kernel (Boot Kernel Collection)
    - Verifies AuxKC if required by policy
    - Constructs final device tree from template + dynamic data
    - Jumps to OS kernel with boot_args in x0
    |
    v
XNU Kernel
    - First point where non-Apple-signed code can run
    - Parses Apple Device Tree (not FDT -- Apple's bespoke format)
    - Initializes Platform Expert, IOKit
```

### 4.2 Virtual Machine Boot Chain

```
AVPBooter.vmapple2.bin (Stage 0, from host VZ framework resources)
    - VM equivalent of SecureROM
    - Validates LLB digest
    - Loads LLB from AuxiliaryStorage
    |
    v
LLB.img4 (Stage 1, from AuxiliaryStorage at offset 0x24000 or 0x224000)
    - Validates iBoot digest
    - Loads iBoot from guest filesystem
    |
    v
iBoot.img4 (Stage 2, from guest filesystem)
    - Validates kernelcache digest
    - Validates AuxKC if present
    - Builds Apple Device Tree for vmapple platform
    - Loads Boot Kernel Collection into memory
    - Jumps to XNU kernel
    |
    v
XNU Kernel (vmapple platform)
    - Expects vmapple-specific device tree nodes
    - Expects vmapple-specific PCI devices
    - Initializes vmapple platform expert
```

### 4.3 AuxiliaryStorage File Format

The AuxiliaryStorage file (~34 MB) contains firmware for the VM boot chain:

```
Offset       Content
0x0000       Header / metadata
0x4000       HUFA structure (set A metadata)
0x5000       HUFA structure (set B metadata)
0x24000      LLB.img4 + logo image (set A)
0x224000     LLB.img4 + logo image (set B)
```

HUFA structure (4096 bytes):
```c
struct HUFA {
    unsigned char magic[4];        // "HUFA"
    uint32_t file_version;         // Always 1
    uint32_t upgrade_count;        // Installation sequence counter
    uint32_t LLB_offset;           // Offset relative to HUFA start
    uint32_t unknown[4];
    unsigned char hash[32];        // SHA-256 hash
    unsigned char fill[4032];      // 0xFF padding
};
```

The active set is determined by the highest `upgrade_count` value. Both sets
store unencrypted LLB images starting with bytes `0x3083` followed by a 3-byte
big-endian length field.

---

## 5. Entitlements and Signing

### 5.1 Required Entitlements

| Entitlement | Source | Required For |
|-------------|--------|-------------|
| `com.apple.security.hypervisor` | **Public** (self-signable) | Basic Hypervisor.framework access |
| `com.apple.security.virtualization` | **Public** (self-signable) | Virtualization.framework access |
| `com.apple.private.hypervisor.vmapple` | **Private** (Apple-only) | vmapple device model in HV |
| `com.apple.private.virtualization` | **Private** (Apple-only) | Advanced VZ features (GDB, ROM loading) |

### 5.2 What Third-Party Developers Can Do

- **Hypervisor.framework** requires only `com.apple.security.hypervisor`, which
  can be self-signed for development: `codesign --sign - --entitlements entitlements.plist binary`
- This gives you: `hv_vm_create()`, `hv_vcpu_create()`, `hv_vcpu_run()`,
  `hv_vm_map()`, register access, interrupt injection, GICv3 support.
- This is sufficient to build a complete VMM for Linux, Windows, or other OSes.

### 5.3 What Third-Party Developers CANNOT Do (Normally)

- The `com.apple.private.hypervisor.vmapple` entitlement is required to enable
  the vmapple device model. Without it, macOS guests cannot find their expected
  hardware platform.
- Workaround: Boot the host Mac with `amfi_get_out_of_my_way=1`, which disables
  AMFI (Apple Mobile File Integrity) and allows arbitrary entitlements to be
  self-signed. **This requires Permissive Security and is not acceptable for
  production deployment.**

### 5.4 Kernel Signature Verification

- **On physical hardware:** The boot chain uses SEP-backed signature verification
  at each stage. Full Security requires Apple-signed firmware. Permissive Security
  allows locally Secure Enclave-signed boot objects (custom XNU kernels).
- **In VMs:** The firmware modules are unencrypted. Signature verification is
  performed by AVPBooter/LLB/iBoot using IMG4 digest checks. These can be patched
  (see Section 2.4), but this requires a modified AVPBooter on the host filesystem,
  which requires SIP modifications.

### 5.5 Trust Caches

macOS on Apple Silicon uses trust caches -- signed lists of CDHashes for binaries
that are allowed to execute. The Boot Kernel Collection contains a trust cache for
kernel extensions. Userspace binaries must be in a trust cache or code-signed.
Bypassing this requires boot arguments like `amfi_get_out_of_my_way=1` or kernel
patching.

---

## 6. XNU Device Tree Requirements

### 6.1 boot_args Structure (ARM64)

XNU receives a pointer to this structure in register x0 at entry:

```c
struct boot_args {
    uint16_t Revision;            // kBootArgsRevision (1 or 2)
    uint16_t Version;             // kBootArgsVersion (1 or 2)
    uint64_t virtBase;            // Virtual memory base address
    uint64_t physBase;            // Physical memory base address
    uint64_t memSize;             // Total memory size
    uint64_t topOfKernelData;     // Highest physical address used by kernel data
    Boot_Video Video;             // Framebuffer configuration
    uint32_t machineType;         // Machine type identifier
    void    *deviceTreeP;         // Pointer to flattened device tree
    uint32_t deviceTreeLength;    // Size of device tree
    char     CommandLine[608];    // Kernel command-line (BOOT_LINE_LENGTH)
    uint64_t bootFlags;           // Additional boot flags (revision 2+)
    uint64_t memSizeActual;       // Actual physical memory size
};
```

### 6.2 Apple Device Tree vs FDT

Apple uses a **bespoke Device Tree format** (Apple Device Tree / ADT), not the
standard Flattened Device Tree (FDT) used by Linux. Key differences:

- Simpler than FDT but similar data model to Open Firmware device trees.
- Schema is not strictly stable across OS versions, but major changes are rare.
- Built by iBoot2 from a template, system configuration data, and dynamic data.
- XNU's `IOKit` framework uses the device tree for platform expert driver matching.

### 6.3 Known Required Device Tree Nodes for XNU ARM64

Based on xnuqemu research and XNU source analysis:

| Node | Purpose | Notes |
|------|---------|-------|
| Root node | Platform identification | `compatible` must include appropriate platform string |
| Memory node | RAM configuration | Required: base address, size. macOS also needs upgradeable RAM info |
| CPU nodes | Processor description | `compatible = "arm,arm-v8"`, reg for each CPU |
| GIC node | Interrupt controller | `compatible = "arm,gic-v3"` with dist/redist reg |
| Timer node | ARM generic timer | `compatible = "arm,armv8-timer"` with IRQ config |
| NVRAM node | Non-volatile storage | **Mandatory** -- kernel panics without it (null pointer during nonce-seed read) |
| AMCC/KTRR regs | Memory protection | Required for memory controller lockdown |
| Chosen node | Boot parameters | Boot arguments, initrd location |
| Serial/UART | Console output | For debug output |

### 6.4 vmapple-Specific Requirements

For the macOS kernel to fully boot on the vmapple platform, the device tree must
describe the vmapple device model. The platform expert in XNU expects:

- vmapple platform identification (model identifier: `VirtualMac2,1`)
- vmapple-specific PCI devices (custom virtio-blk extensions, apple-gfx, AES engine)
- vmapple backdoor interface (BDIF) for host-guest communication
- vmapple configuration device for machine-specific settings

**The vmapple platform expert code is in XNU's closed-source portions.**
We do not have visibility into exactly what it checks.

### 6.5 VZ Linux Guest Device Tree (Reference)

The VZ FDT for Linux guests (extracted by zhuowei) uses these addresses:

```
GIC Distributor:     0x10000000 (64 KB)
GIC Redistributor:   0x10010000 (128 KB)
PL031 RTC:           0x20050000 (4 KB)
PL061 GPIO:          0x20060000 (4 KB)
pvpanic-mmio:        0x20070000 (2 bytes)
PCI ECAM:            0x40000000 (256 MB)
PCI 32-bit MMIO:     0x50000000 (~503 MB)
PCI I/O:             0x6FFF0000 (64 KB)
Guest RAM:           0x70000000 (variable)
PCI 64-bit MMIO:     0x100000000 (1 GB)
```

PSCI method is HVC with standard PSCI 0.2 function IDs. Timer uses standard
ARMv8 timer IRQs.

---

## 7. Feasibility Assessment

### Approach A: Direct Firmware Load from IPSW

**Concept:** Extract iBoot (or AVPBooter) from the IPSW, load it into our VM's
flash region, and let it boot the macOS kernel normally.

**Assessment: NOT FEASIBLE (1/10)**

Reasons:
1. **iBoot/LLB/iBSS in the IPSW are AES-encrypted.** We do not have the keys.
   We cannot extract usable firmware binaries from the IPSW for physical hardware.
2. **AVPBooter.vmapple2.bin is not in the IPSW.** It is a host-side component
   shipped with Virtualization.framework. It can be copied from the host, but:
3. **AVPBooter requires the vmapple HV mode**, enabled by the private entitlement
   `com.apple.private.hypervisor.vmapple`. Without this entitlement, we cannot
   present the hardware model that AVPBooter expects.
4. **Even if we load AVPBooter**, it will try to validate LLB, which requires
   correct AuxiliaryStorage format and IMG4 signatures. Without patching AVPBooter
   (which requires modifying the host OS), the chain of trust stops here.
5. **The entire vmapple device model is proprietary.** iBoot builds a device tree
   for hardware we don't emulate (apple-gfx, BDIF, vmapple-virtio-blk extensions,
   AES engine). Even if the firmware boots, the kernel would find none of its
   expected devices.

### Approach B: Minimal Firmware Shim (Direct Kernel Load)

**Concept:** Skip the entire Apple firmware chain. Extract the kernelcache from
the IPSW, construct our own boot_args and device tree, and jump directly to the
XNU entry point (like xnuqemu does).

**Assessment: THEORETICALLY POSSIBLE, PRACTICALLY VERY DIFFICULT (3/10)**

What works:
1. The kernelcache is unencrypted and extractable from the IPSW.
2. The boot_args structure is documented in Apple's open-source XNU headers.
3. xnuqemu proved the kernel can be loaded this way -- it booted to launchd.
4. Hypervisor.framework gives us everything we need for CPU/memory/interrupts.

What doesn't work (yet):
1. **Device tree construction:** XNU for vmapple expects Apple Device Tree format
   (not FDT) with vmapple-specific nodes. We would need to either:
   - Reverse-engineer the exact ADT that iBoot builds for vmapple, or
   - Present a different platform identity and provide matching drivers.
2. **Platform expert matching:** XNU's IOKit matches the platform expert based on
   device tree compatible strings. The vmapple platform expert is closed-source.
   Using a different compatible string (e.g., mimicking a physical Mac) would
   require providing all the hardware those drivers expect.
3. **Trust cache / code signing:** Without `amfi_get_out_of_my_way=1` or kernel
   patching, userspace binaries won't execute. The kernel itself can be loaded
   unsigned, but the userspace security model is intact.
4. **Disk drivers:** macOS uses custom vmapple-virtio-blk with nonstandard
   extensions. Standard virtio-blk won't work. We'd need to either reverse-engineer
   the vmapple extensions or somehow get macOS to use standard virtio (it won't
   have drivers for standard virtio-blk).
5. **Display driver:** macOS in VMs uses apple-gfx, a paravirtualized display
   backed by ParavirtualizedGraphics.framework. Standard virtio-gpu won't work.
6. **Half of kernel extensions fail** even in xnuqemu's minimal environment.
   A functional macOS userspace requires dozens of working kext matches.

**Bottom line:** We can get to early kernel boot, but reaching a functional
desktop requires reverse-engineering and reimplementing the entire vmapple device
model -- a multi-year effort with ongoing breakage as Apple changes the model
between macOS versions.

### Approach C: Hybrid VZ Boot + Device Takeover

**Concept:** Use Virtualization.framework for the macOS boot chain and initial
device setup, then "take over" specific devices (particularly audio) with our
own implementation.

**Assessment: MOST FEASIBLE, WITH SIGNIFICANT CONSTRAINTS (6/10)**

How it would work:
1. Use VZ's `VZMacOSBootLoader` and `VZMacOSInstaller` for the complete boot chain.
2. Use VZ's standard device set for disk, network, GPU.
3. For audio: **do not use** `VZVirtioSoundDeviceConfiguration`.
4. Instead, use VZ's `VZVirtioSocketDevice` (vsock) as a data channel.
5. Implement a custom audio daemon inside the guest that:
   - Presents a virtual CoreAudio device to guest applications.
   - Captures audio data and sends it over vsock to the host.
6. On the host side, receive audio over vsock and route it to specific
   CoreAudio devices using our own AudioUnit pipeline.

Advantages:
- Proven boot chain -- VZ handles all firmware complexity.
- Most devices work out of the box.
- Audio routing is fully under our control on the host side.
- No private entitlements needed (VZ handles that internally).
- No host OS modifications needed.

Constraints and risks:
- **Latency:** vsock adds a hop vs direct virtio-snd. Need to measure.
- **Guest agent required:** A daemon must run inside the macOS guest.
- **Guest audio driver:** Need a virtual CoreAudio driver (DriverKit HAL plugin)
  inside the guest to redirect audio to the vsock channel.
- **VZ version coupling:** Tied to VZ's API surface and behavior changes.
- **No control over other devices:** Cannot customize GPU, USB, etc.
- **2 VM limit:** The kernel enforces max 2 macOS VMs via `hv_apple_isa_vm_quota`.
  Can be overridden with boot arguments on development kernels, but not in production.

### Approach D: VZ Boot + Custom Virtio-Snd (Hybrid, Audio-Focused)

**Concept:** Use VZ for boot, but inject our own virtio-snd device alongside
(or replacing) VZ's audio device.

**Assessment: UNCERTAIN, REQUIRES INVESTIGATION (4/10)**

This would require:
1. Omitting `VZVirtioSoundDeviceConfiguration` from the VZ config.
2. Finding a way to present our own PCI device to the guest. VZ does not have a
   public API for custom PCI device injection.
3. Possibly using private/undocumented VZ APIs (risky, version-fragile).
4. The guest macOS would need a driver for our custom device.

This is speculative and depends on undocumented VZ capabilities.

---

## 8. Recommended Path Forward

### 8.1 Primary Strategy: Approach C (Hybrid VZ + vsock Audio)

This is the only approach with a realistic timeline for the first milestone:

1. **Use Virtualization.framework** for macOS guest lifecycle (install, boot, stop).
2. **Skip VZ audio entirely** -- do not add `VZVirtioSoundDeviceConfiguration`.
3. **Build a vsock-based audio bridge:**
   - Host side: VortexAudio module manages per-VM CoreAudio AudioUnit instances,
     each targeting a specific output device.
   - Guest side: A DriverKit-based HAL audio plugin that captures/plays audio and
     tunnels PCM data over virtio-vsock.
   - Lock-free ring buffer between vsock and AudioUnit callback threads.
4. **Measure latency.** If vsock latency is unacceptable (>10ms additional), fall
   back to shared memory approaches.

### 8.2 Investigation Track: Custom VMM for macOS (Long-Term)

In parallel, continue investigating:

1. **The `com.apple.private.hypervisor.vmapple` entitlement.** Can it be obtained
   through Apple's enterprise/partner programs? File a Developer Technical Support
   request to ask.
2. **QEMU's vmapple implementation.** Study `hw/vmapple/` for the device model
   details. Even though it only works with macOS 12, it's the best reference for
   what the vmapple platform expects.
3. **XNU source code analysis.** Study the Platform Expert code, device tree parsing,
   and IOKit matching in the public XNU source to understand what nodes are required.
4. **DTB extraction from running VZ VMs.** Use `ioreg` or memory dumps to capture
   the actual Apple Device Tree that a running macOS guest sees.
5. **Firmware behavior analysis.** Use dtrace, LLDB, and Instruments on the VZ XPC
   service to observe what HV APIs it calls during macOS guest boot.

### 8.3 Risk Register

| Risk | Severity | Mitigation |
|------|----------|------------|
| Private entitlement blocks custom VMM | **Critical** | Approach C avoids this entirely |
| vsock audio latency too high | **High** | Benchmark early; investigate shared memory as fallback |
| Guest DriverKit HAL plugin complexity | **High** | Start with a minimal virtual audio driver; iterate |
| VZ API changes break integration | **Medium** | Pin to specific macOS versions; test on betas |
| 2 VM limit for macOS guests | **Medium** | Acceptable for initial use cases; investigate kernel boot-arg for development |
| vmapple device model changes between macOS versions | **Medium** | Only applies to custom VMM track |
| Apple removes or restricts VZ features | **Low** | VZ is a public, documented API with App Store apps depending on it |

---

## 9. Key Technical References

### Apple Documentation
- [Boot process for a Mac with Apple silicon](https://support.apple.com/guide/security/boot-process-secac71d5623/web)
- [Startup Disk security policy control](https://support.apple.com/guide/security/startup-disk-security-policy-control-sec7d92dc49f/web)
- [com.apple.security.hypervisor entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.hypervisor)
- [com.apple.security.virtualization entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization)
- [Virtualization framework](https://developer.apple.com/documentation/virtualization)
- [Hypervisor framework](https://developer.apple.com/documentation/hypervisor)
- [VZMacOSBootLoader](https://developer.apple.com/documentation/virtualization/vzmacosbootloader)
- [VZVirtioSoundDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtiosounddeviceconfiguration)

### Asahi Linux / m1n1
- [Introduction to Apple Silicon](https://asahilinux.org/docs/platform/introduction/)
- [Apple Silicon Boot Flow](https://asahilinux.org/docs/fw/boot/)
- [Open OS Platform Interoperability](https://asahilinux.org/docs/platform/open-os-interop/)
- [m1n1 source (GitHub)](https://github.com/AsahiLinux/m1n1)
- [m1n1-xnu-boot (jevinskie)](https://github.com/jevinskie/m1n1-xnu-boot)

### Reverse Engineering & Research
- [Notes on Virtualization.framework reversing (kel.bz)](https://kel.bz/post/virtualization-framework-reversing/)
- [Booting a macOS Apple Silicon kernel in QEMU (worthdoingbadly)](https://worthdoingbadly.com/xnuqemu3/)
- [Virtualizing iOS on Apple Silicon (Nick Botticelli)](https://nickb.website/blog/virtualizing-ios-on-apple-silicon)
- [vma2pwn (GitHub)](https://github.com/nick-botticelli/vma2pwn)
- [Virtual-iBoot-Fun (NyanSatan)](https://github.com/NyanSatan/Virtual-iBoot-Fun)
- [Running Third Party Kexts on VZ Guest VMs (steven-michaud)](https://gist.github.com/steven-michaud/fda019a4ae2df3a9295409053a53a65c)
- [Custom Boot Objects in VZ Guest VMs (steven-michaud)](https://gist.github.com/steven-michaud/16cff5628850799e428a2f2c56029677)
- [VZ XPC Service Entitlements (woachk)](https://gist.github.com/woachk/30baddae2fd76adc75aa9db12496ddd4)
- [VZ Linux Guest Device Tree (zhuowei)](https://gist.github.com/zhuowei/d9871eb897d41ece0bcc5cf46c805fb2)
- [Beating the 2 VM Limit (khronokernel)](https://khronokernel.com/macos/2023/08/08/AS-VM.html)
- [VM Serials and DEP (khronokernel)](https://khronokernel.com/macos/2023/08/18/AS-VM-SERIAL.html)

### QEMU
- [VMApple machine emulation docs](https://www.qemu.org/docs/master/system/arm/vmapple.html)
- [QEMU vmapple PV Graphics patch series](https://patchew.org/QEMU/20240928085727.56883-1-phil@philjordan.eu/)
- [QEMU HVF aarch64 patches](https://lore.kernel.org/qemu-devel/db51fd0c-42c0-19c0-2049-bb56e88c4b51@redhat.com/T/)

### XNU Source Code
- [apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu)
- [boot.h (ARM64 boot_args)](https://github.com/apple/darwin-xnu/blob/main/pexpert/pexpert/arm64/boot.h)
- [arm_vm_init.c](https://github.com/apple/darwin-xnu/blob/main/osfmk/arm64/arm_vm_init.c)

### Existing macOS VM Tools
- [Tart (Cirrus Labs)](https://github.com/cirruslabs/tart) -- VZ-based macOS/Linux VMs
- [UTM](https://mac.getutm.app/) -- QEMU + VZ, macOS guests via VZ only
- [Bring Your Own VM - Mac Edition (xpnsec)](https://blog.xpnsec.com/bring-your-own-vm-mac-edition/)
- [Arm VMM with Apple's Hypervisor Framework (whexy)](https://www.whexy.com/en/posts/simpple_01)

### Other
- [IPSW File Format (The Apple Wiki)](https://theapplewiki.com/wiki/IPSW_File_Format)
- [IPSW tool (blacktop)](https://github.com/blacktop/ipsw)
- [Virtualisation on Apple silicon Macs (Eclectic Light)](https://eclecticlight.co/2022/07/12/virtualisation-on-apple-silicon-macs-3-configuration-vm-and-boot/)

---

## 10. Open Questions for Further Investigation

1. **Can `com.apple.private.hypervisor.vmapple` be obtained legitimately?**
   File a DTS request. If Apple grants this entitlement to partner VMM developers,
   the entire project scope changes.

2. **What exactly does the vmapple HV mode do?**
   Does it enable special registers, MMIO regions, or interrupt behavior that
   standard HV mode doesn't have? Or is it just an entitlement gate?

3. **Can we present a non-vmapple platform to macOS?**
   What if we present a device tree identifying as a physical Mac (e.g., Mac14,2)?
   XNU would expect IOKit drivers for physical hardware, but would the kernel at
   least boot? This needs testing.

4. **What is the exact Apple Device Tree format?**
   m1n1 parses it; the format is documented in Asahi Linux's work. Can we
   construct one from scratch for a vmapple-like platform?

5. **Can vsock achieve <5ms round-trip for audio?**
   This determines whether Approach C is viable for professional audio use cases.
   Benchmark with 48kHz/16-bit stereo, 256-sample buffers.

6. **What DriverKit APIs are needed for a virtual HAL audio plugin?**
   Specifically, can a DriverKit audio driver present a CoreAudio device inside
   a macOS guest? Or does this require a traditional kext (which would need the
   complex kext approval process)?

7. **Does macOS 15+ change the vmapple model?**
   QEMU's vmapple only works with macOS 12. Parallels and VZ handle newer versions.
   What changed in the device model?
