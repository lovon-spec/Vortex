# macOS Guest Audio Device Analysis

**Date:** 2026-03-31
**Purpose:** Determine which audio device model Vortex should emulate for macOS guest audio support.
**Verdict:** macOS ships a built-in **virtio-snd** driver. We emulate a standard virtio-snd PCI device.

---

## Executive Summary

macOS (at least since Ventura/Sonoma, confirmed on the current host running macOS 26 Tahoe)
ships `AppleVirtIOSound` as a personality inside the `AppleVirtIO.kext` kernel extension.
This driver matches **standard virtio-snd devices** (Virtio Device ID 25, PCI Vendor 0x1AF4).
No custom Apple device IDs are required. This is our primary path: Vortex emulates a
spec-compliant virtio-snd PCI device, and the macOS guest picks it up with zero guest
modifications.

Intel HDA is **not viable** on Apple Silicon macOS -- the generic `AppleHDA.kext` was never
shipped for ARM64 and has been fully removed as of macOS 26 Tahoe. AC97 is completely absent.

---

## 1. Intel HDA (High Definition Audio)

### Finding: NOT VIABLE for macOS on Apple Silicon

**Does macOS ship an Intel HDA class driver?**

- **No generic `AppleHDA.kext` exists on Apple Silicon.** The kext was historically present on
  Intel Macs for Realtek/Conexant/etc. codec support via the HDA bus. It was never ported to
  ARM64 because Apple Silicon Macs use a completely different audio subsystem (Apple-custom DMA
  controllers communicating with Apple-designed audio chips via IPC, not HDA).

- **`AppleHDA.kext` has been fully removed as of macOS 26 (Tahoe).** Even on Intel Macs, Apple
  dropped it because the last supported Intel Macs all have T2 chips that handle audio
  independently of HDA. The Hackintosh community has documented this removal extensively.

- **`AppleGFXHDA.kext` exists but is GPU-only.** This kext handles HDMI/DisplayPort audio output
  from GPUs (AMD Radeon and specific Intel HD Audio controller variants). It matches only these
  specific PCI devices:

  | Personality | IOClass | IOPCIMatch (Vendor:Device) |
  |---|---|---|
  | AMD | AppleGFXHDAEGController | AMD GPU audio: 0xAAF81002, 0xAAF01002, 0xABF81002, 0xAB201002, 0xAAE01002, 0xAB381002, 0xAB281002 |
  | Intel (9DC8) | AppleGFXHDA8086_9DC8Controller | 0x9DC88086, 0xA3488086 |
  | Intel (9D71) | AppleGFXHDA8086_9D71Controller | 0x9D718086, 0x34C88086 |
  | Intel (38C8) | AppleGFXHDA8086_38C8Controller | 0x38C88086 |

  These are all GPU HDMI audio controllers, not general-purpose HDA codecs. They would not
  provide general audio input/output for a VM guest.

**QEMU/UTM experience with Intel HDA:**

- The OSX-KVM project used `-device intel-hda -device hda-duplex` with the third-party
  `VoodooHDA.kext` to provide audio in macOS guests on x86. This required injecting VoodooHDA
  via OpenCore.
- VoodooHDA worked only up to macOS Big Sur 11.2. It stopped loading from Big Sur 11.3 onward
  due to kext loading restrictions.
- Audio quality was reported as "choppy and distorted" even when working.
- This approach requires kext injection, SIP modification, and is Intel-only. **Not viable for
  ARM64 VMs.**

### Conclusion

Intel HDA emulation is a dead end for macOS guests on Apple Silicon. There is no driver that
would match it, and injecting third-party kexts into macOS ARM64 VMs is extremely difficult
(requires binary patching of boot chain components -- see Section 6).

---

## 2. AC97

### Finding: COMPLETELY ABSENT

No AC97-related kexts, drivers, or IOKit personalities exist anywhere in the macOS system
extensions. AC97 support was never included in macOS (Apple transitioned from USB audio and
custom audio chips to HDA on Intel Macs, never using AC97). This is not a viable path.

---

## 3. Virtualization.framework's Audio Device

### Finding: STANDARD VIRTIO-SND (This is our path)

**What VZ creates:** When Apple's Virtualization.framework creates a macOS VM with
`VZVirtioSoundDeviceConfiguration`, it presents a **standard virtio-snd PCI device** to the
guest. This is NOT an Apple-custom device -- it uses the standard Virtio vendor and device IDs.

**PCI-level matching (transport layer):**

The `AppleVirtIOPCITransport` personality in `AppleVirtIO.kext` matches:

```
IOPCIPrimaryMatch = "0x00001af4&0x0000FFFF"
```

This matches **any PCI device with vendor ID 0x1AF4** (the standard Virtio vendor), regardless
of the specific PCI device ID. This means it will match both:
- Non-transitional (modern) devices: PCI Device ID 0x1059 (= 0x1040 + 25)
- Transitional devices: PCI Device ID in 0x1000-0x103F range with appropriate subsystem ID

**Virtio transport-level matching (sound driver):**

Once the PCI transport layer creates an `AppleVirtIOTransport` provider, the `AppleVirtIOSound`
personality matches:

```
IOVirtIOPrimaryMatch = "0x00191af4"
```

This encodes: **Virtio Device ID 0x0019 (25) + Vendor ID 0x1AF4**. Device ID 25 is the standard
virtio-snd device ID per the OASIS Virtio specification.

**Full IOKit matching chain:**

```
IOPCIDevice (vendor=0x1AF4, device=0x1059)
  -> AppleVirtIOPCITransport (matches vendor 0x1AF4)
    -> AppleVirtIOTransport (exposes virtio device ID 0x0019)
      -> AppleVirtIOSound (matches device ID 0x0019 + vendor 0x1AF4)
```

**IOKit class details:**

| Key | Value |
|---|---|
| Bundle | com.apple.driver.AppleVirtIO |
| IOClass | AppleVirtIOSound |
| IOProviderClass | AppleVirtIOTransport |
| IOUserClientClass | AppleVirtIOSoundUserClient |
| IOVirtIOPrimaryMatch | 0x00191af4 |
| Product Name | "VirtIO Sound" |

**Apple-custom vs. Standard devices:**

Apple uses TWO patterns in their VirtIO implementation:
1. **Standard Virtio devices** (vendor 0x1AF4): Used for devices with upstream spec support --
   network (0x0001), block (0x0002), console (0x0003), entropy (0x0004), balloon (0x0005),
   9P (0x0009), input (0x0012), vsock (0x0013), IOMMU (0x0017), **sound (0x0019)**, FS (0x001A)
2. **Apple-custom Virtio devices** (vendor 0x106B = Apple): Used for Apple-proprietary devices --
   storage (0x1A00), USB (0x1A01), neural engine (0x1A02), HID bridge (0x1A04),
   power source (0x1A07), biometrics (0x1A0A), identity (0x1A0C), private vsock (0x1A0D)

The sound device uses pattern #1 -- **standard Virtio, not Apple-custom.** This is the critical
finding: we do not need to reverse-engineer any Apple proprietary protocol.

---

## 4. Standard Virtio-snd

### Finding: SUPPORTED NATIVELY in macOS

**Does macOS include a driver for standard virtio-snd?**

**YES.** The `AppleVirtIOSound` class in `AppleVirtIO.kext` (bundle version 248, currently
loaded in the kernel as confirmed by `kextstat`) handles standard virtio-snd devices.

**PCI Identity for our emulated device:**

| Field | Value | Notes |
|---|---|---|
| PCI Vendor ID | 0x1AF4 | Standard Virtio vendor (Red Hat/OASIS) |
| PCI Device ID | 0x1059 | Non-transitional: 0x1040 + device ID 25 |
| PCI Subsystem Vendor ID | 0x1AF4 | Standard |
| PCI Subsystem Device ID | 0x0019 | Virtio device ID (sound) |
| PCI Revision ID | 1 | Non-transitional device (>=1) |
| PCI Class Code | 0x040100 | Multimedia controller, audio device |

**Alternative (transitional) identity:**

| Field | Value |
|---|---|
| PCI Vendor ID | 0x1AF4 |
| PCI Device ID | 0x1050 | Transitional range (could also work) |
| PCI Subsystem Device ID | 0x0019 |
| PCI Revision ID | 0 |

**Recommendation:** Use the non-transitional (modern) identity. Apple's PCI transport matches
on vendor only (`0x00001af4&0x0000FFFF`), so it will work with either device ID. The
non-transitional approach is cleaner and aligns with Virtio 1.2 spec.

**Virtio-snd Specification (OASIS Virtio v1.2, Section 5.14):**

The virtio-snd device uses 4 virtqueues:

| Queue Index | Name | Direction | Purpose |
|---|---|---|---|
| 0 | controlq | Guest -> Host | Device configuration, stream params, jack info |
| 1 | eventq | Host -> Guest | Asynchronous events (jack state changes, etc.) |
| 2 | txq | Guest -> Host | PCM playback data (guest audio output) |
| 3 | rxq | Host -> Guest | PCM capture data (guest audio input) |

**Feature bits:**

| Feature Bit | Name | Description |
|---|---|---|
| Bit 0 | VIRTIO_SND_F_CTLS | Device has audio controls (volume, mute, etc.) |

**Configuration space layout (read-only from device):**

```
struct virtio_snd_config {
    le32 jacks;     // Number of available jacks (physical connectors)
    le32 streams;   // Number of available PCM streams
    le32 chmaps;    // Number of available channel maps
};
```

**QEMU's implementation reference:**

QEMU's `virtio-sound-pci` device (added in QEMU 8.2.0) provides:
- Configurable `jacks`, `streams`, `chmaps` counts
- First stream is always playback, optional second is capture
- All streams are stereo (front left/right)
- Jack and channel map features are listed as unimplemented in QEMU
- Backend: CoreAudio supported (relevant for our host-side)

**What we need to implement:**

For our minimum viable virtio-snd device:
1. PCI config space with correct identity (above table)
2. Virtio common/ISR/device-specific/notification capability structures
3. Feature negotiation (VIRTIO_F_VERSION_1 + optionally VIRTIO_SND_F_CTLS)
4. Configuration space reporting at least 1 stream (playback) + 1 stream (capture)
5. Control virtqueue handling: respond to VIRTIO_SND_R_PCM_INFO, SET_PARAMS, PREPARE, START,
   STOP, RELEASE messages
6. TX virtqueue: receive PCM buffers from guest, feed to host CoreAudio output
7. RX virtqueue: capture from host CoreAudio input, deliver to guest
8. MSI-X interrupts for used buffer notifications

---

## 5. IOKit Audio Driver Landscape

### Complete Inventory of Audio-Related Kexts

All kexts found in `/System/Library/Extensions/` on macOS 26 (Tahoe) Apple Silicon:

**Apple Silicon Native Audio (hardware-specific, not relevant for VM):**

| Kext | Purpose |
|---|---|
| AppleAOPAudio.kext | Always-On Processor audio (AirPods, Hey Siri) |
| AOPAudioDriver.kext | AOP audio driver |
| AppleARMIISAudio.kext | I2S audio interface (Apple Silicon DAC) |
| AppleCSEmbeddedAudio.kext | Cirrus Logic codec support |
| AppleEmbeddedAudio.kext | Built-in speaker/mic management |
| AppleEmbeddedAudioLibs.kext | Audio processing libraries |
| AppleIPCAudioController.kext | IPC-based audio controller |
| AppleIPCAudioDeviceProxy.kext | IPC audio device proxy |
| AppleAudioClockLibs.kext | Audio clock synchronization |
| AppleAudioRemoteIICController.kext | Remote I2C audio controller |
| BridgeAudioCommunication.kext | T2/Bridge chip audio |
| BridgeAudioController.kext | T2/Bridge chip audio controller |
| ExclavesAudioKext.kext | Secure enclave audio processing |
| AudioDMAController_T*.kext | DMA controllers (per-SoC: T8103, T8112, T600x, etc.) |
| AudioDMAFamily.kext | DMA controller family |
| AudioDMACLLTEscalationDetector_*.kext | DMA latency monitoring |

**Audio Frameworks (relevant for driver model understanding):**

| Kext | Purpose |
|---|---|
| IOAudioFamily.kext | Legacy IOAudio driver family (empty IOKitPersonalities) |
| IOAudio2Family.kext | Modern IOAudio2 driver family (empty IOKitPersonalities) |
| IOPAudioDriverFamily.kext | IOP audio driver family |
| IOPAudio*.kext (many) | IOP audio subsystem components |
| AudioAUUC.kext | Audio Unit user client |

**GPU HDMI/DP Audio:**

| Kext | Purpose |
|---|---|
| AppleGFXHDA.kext | GPU HDMI/DisplayPort audio (AMD + specific Intel GPU audio) |

**USB Audio:**

| Kext | Purpose |
|---|---|
| AppleUSBAudio.kext | USB Audio Class device support |

**Virtualization Audio (THE ONE WE CARE ABOUT):**

| Kext | Purpose |
|---|---|
| AppleVirtIO.kext | Contains `AppleVirtIOSound` personality matching virtio-snd |

**HAL Plugins (user-space audio drivers, on host):**

Found in `/Library/Audio/Plug-Ins/HAL/`:

| Plugin | Purpose |
|---|---|
| BlackHole2ch.driver | BlackHole 2-channel virtual audio loopback |
| BlackHole16ch.driver | BlackHole 16-channel virtual audio loopback |
| ParrotAudioPlugin.driver | Parrot audio plugin |

### Key Observations

1. **No generic HDA controller driver exists on Apple Silicon.** Only `AppleGFXHDA` for
   GPU audio output, matching specific AMD and Intel GPU PCI IDs.
2. **No AC97 driver exists.**
3. **The only PCI audio driver that could work in a VM is `AppleVirtIOSound`** inside
   `AppleVirtIO.kext`, matching standard virtio-snd devices.
4. **USB audio (`AppleUSBAudio`) could theoretically work** if we emulated an xHCI controller
   with a USB Audio Class device, but this adds massive complexity (xHCI + USB Audio Class
   emulation) compared to virtio-snd.

---

## 6. Guest Driver Feasibility (Fallback Analysis)

If virtio-snd does not work for some reason, could we write a custom guest audio driver?

### Option A: Kernel Extension (kext)

**Verdict: Extremely difficult, effectively not viable.**

- **SIP must be disabled** in the guest macOS VM.
- On Apple Silicon, loading third-party kexts requires:
  1. Booting into Recovery (1TR mode)
  2. Downgrading to "Reduced Security"
  3. Explicitly enabling kernel extensions
- **In Virtualization.framework VMs, third-party kexts are not supported at all.** Apple
  closed a Feedback report stating this is "Works as currently designed: '3rd party kext (auxKC)
  isn't supported on macOS VMs'."
- A workaround exists involving binary patching of three iBoot stages and the kernel cache,
  documented by Steven Michaud. This requires patching `AVPBooter.vmapple2.bin`, modifying
  LLB, iBoot, and the kernel collection using Ghidra/Hopper. This is fragile, breaks with
  every macOS update, and is not suitable for a production VMM.
- Kext code signing requires a special Apple-issued certificate that Apple grants only after
  reviewing the company and use case.
- **Apple's official position:** "Kexts are no longer recommended for macOS."

### Option B: DriverKit System Extension (dext)

**Verdict: Not viable for virtual audio devices.**

- AudioDriverKit (introduced in macOS Monterey/WWDC21) provides user-space audio driver
  development via DriverKit.
- **However, Apple explicitly states that AudioDriverKit will NOT be approved for virtual audio
  devices.** The entitlement will not be granted. This was stated directly in Apple Developer
  Forums (thread 682035).
- AudioDriverKit is designed for real hardware devices (USB, PCIe) communicating through
  USBDriverKit or PCIDriverKit.
- For virtual audio devices, Apple directs developers to use AudioServerPlugin (HAL plugin).

### Option C: AudioServerPlugin (HAL Plugin)

**Verdict: Viable for HOST-side routing, but requires installation INSIDE the guest.**

- An AudioServerPlugin is a user-space CoreAudio driver installed in
  `/Library/Audio/Plug-Ins/HAL/` with the `.driver` extension.
- It runs in its own sandboxed process, no kernel extension needed.
- This is how BlackHole, Loopback, and other virtual audio devices work on macOS.
- **The problem for VM guests:** We would need to install a custom HAL plugin inside the
  macOS guest. This requires either:
  - Guest tools that automatically install the plugin
  - User manually installing it
- The plugin would need some communication channel back to the VMM (e.g., via a virtio-vsock
  connection or shared memory region).
- Libraries like [libASPL](https://github.com/gavv/libASPL) (C++17) make HAL plugin
  development relatively straightforward.
- **This is our backup plan** if virtio-snd proves insufficient, but it requires guest
  modification and a custom communication protocol.

### Option D: USB Audio Class Emulation

**Verdict: Technically possible but high complexity.**

- macOS ships `AppleUSBAudio.kext` which matches USB Audio Class devices (bInterfaceClass=1).
- We could emulate an xHCI USB controller with a virtual USB Audio Class device attached.
- The guest would see it as a standard USB audio device with no driver installation needed.
- **Downsides:** Requires full xHCI controller emulation + USB protocol emulation + USB Audio
  Class protocol emulation. This is orders of magnitude more complex than virtio-snd.
- **Latency:** USB Audio adds protocol overhead that virtio-snd avoids.

### Recommendation

**Primary: virtio-snd** (zero guest modification, standard protocol, native driver exists).
**Backup: AudioServerPlugin inside guest** (requires guest tools, custom protocol).
**Last resort: USB Audio Class** (no guest mod needed, but extreme implementation complexity).

---

## 7. UTM/QEMU macOS Audio Experience

### Current State of Art

**UTM with Apple Virtualization backend (macOS guests):**

- Sound IS supported for macOS guests using Apple Virtualization backend.
- Uses `VZVirtioSoundDeviceConfiguration` which creates a virtio-snd device.
- The guest macOS loads `AppleVirtIOSound` driver automatically.
- Audio playback generally works. Some reports of issues with microphone input.
- The audio entitlement was missing in some signed UTM builds (issue #4342), causing audio
  to not work in App Store versions.
- UTM 4.2.4+ added fixes for Apple Virtualization sound.
- A known limitation: enabling sound device can interfere with VM save/restore state
  (you must remove Sound and Entropy devices to use save/restore for macOS Sonoma guests).

**UTM with QEMU backend (macOS guests):**

- QEMU backend offers Intel HDA emulation (`intel-hda` + `hda-duplex`).
- For macOS guests, this requires injecting `VoodooHDA.kext` via OpenCore.
- VoodooHDA only works up to macOS Big Sur 11.2.
- Audio quality is poor: "choppy and distorted."
- QEMU 8.2.0+ added `virtio-sound-pci` device. UTM integrated this in version 4.6.2
  (October 2024) for Linux guests.
- For macOS guests under QEMU backend, virtio-snd may work IF the guest has
  `AppleVirtIOSound` driver AND QEMU presents the device correctly. However, QEMU's ARM
  virt machine type with macOS is not officially supported.

**Parallels Desktop:**

- Parallels emulates a virtual sound device and requires Parallels Tools installed in guest.
- Audio generally works but some users report issues at certain sample rates (workaround:
  change guest audio sampling rate to 22 KHz).
- Internal implementation details are proprietary.

**Key Takeaway:**

The working, proven path for macOS guest audio on Apple Silicon is virtio-snd via the
Virtualization.framework model. Both UTM (Apple Virtualization mode) and Apple's own
sample code use `VZVirtioSoundDeviceConfiguration`, which presents a standard virtio-snd
device that macOS recognizes natively.

---

## 8. Implementation Plan for Vortex

### Primary Strategy: Emulate Standard Virtio-snd

```
                   macOS Guest
                   +-----------------------+
                   | CoreAudio             |
                   |   |                   |
                   | AppleVirtIOSound      |
                   |   |                   |
                   | AppleVirtIOTransport  |
                   |   |                   |
                   | AppleVirtIOPCITransport|
                   +----|------------------+
                        | PCI MMIO / MSI-X
                   -----+--------- VM Exit ---------
                        |
                   Vortex VMM (Host)
                   +----|------------------+
                   | VirtioSoundDevice     |
                   |   |                   |
                   | controlq | txq | rxq  |
                   |   |                   |
                   | AudioUnit (per-VM)    |
                   |   -> specific device  |
                   +-----------------------+
```

### PCI Configuration

Present the following PCI device:
- **Vendor ID:** 0x1AF4
- **Device ID:** 0x1059 (non-transitional virtio-snd)
- **Subsystem Vendor ID:** 0x1AF4
- **Subsystem Device ID:** 0x0019
- **Revision ID:** 1
- **Class Code:** 0x040100 (Multimedia audio controller)
- **Capabilities:** MSI-X, Virtio common cfg, ISR, device cfg, notification

### Virtio Configuration

- **Feature bits:** VIRTIO_F_VERSION_1 (bit 32), VIRTIO_SND_F_CTLS (bit 0, optional)
- **Config space:** jacks=0, streams=2, chmaps=0 (minimum: 1 output + 1 input stream)
- **Virtqueues:** 4 (controlq, eventq, txq, rxq)
- **Notification:** Per-queue MSI-X vectors

### Host-Side Audio Routing (Per-VM)

Each VM's VirtioSoundDevice connects to its own `AudioUnit` instances:
- **Output (txq):** Lock-free ring buffer between virtio thread and AudioUnit render callback.
  AudioUnit configured with `kAudioUnitSubType_HALOutput`, output device set to
  VM-specific AudioDeviceID via `kAudioOutputUnitProperty_CurrentDevice`.
- **Input (rxq):** Same AudioUnit type, input scope, lock-free ring buffer in opposite direction.
- **Never touch system default device.** Each VM targets a specific device by UID.

### Development Priority

1. **Phase 1:** Virtio-snd PCI device identity + feature negotiation + config space
2. **Phase 2:** Control virtqueue (PCM_INFO, SET_PARAMS, PREPARE, START, STOP, RELEASE)
3. **Phase 3:** TX virtqueue (playback) with CoreAudio output
4. **Phase 4:** RX virtqueue (capture) with CoreAudio input
5. **Phase 5:** MSI-X interrupt delivery for used buffer notifications
6. **Phase 6:** Per-VM device routing via AudioDeviceID selection

---

## 9. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| AppleVirtIOSound requires Apple-proprietary virtio extensions | LOW | HIGH | Analyzed kext matching -- uses standard device IDs. Confirmed by UTM/VZ behavior. |
| AppleVirtIOSound expects specific stream config or features | MEDIUM | MEDIUM | Start with QEMU-compatible config (2 streams, no jacks). Test incrementally. |
| Audio latency too high through virtio ring buffers | MEDIUM | MEDIUM | Use small buffer sizes, lock-free rings, RT-priority audio thread. |
| AppleVirtIOSound not present in older macOS versions | LOW | LOW | Target macOS 14+ (Sonoma). Driver confirmed present. |
| macOS guest refuses to output to virtual audio device | LOW | HIGH | The guest just sees a standard audio device. CoreAudio inside guest handles routing normally. |
| Future macOS removes or changes AppleVirtIOSound | LOW | MEDIUM | Apple uses this for their own VZ framework -- unlikely to remove. |

---

## 10. Open Questions

1. **Exact virtio-snd protocol compliance required by AppleVirtIOSound:** Does it need all
   control messages implemented, or just a subset? Will need to test empirically.

2. **Supported audio formats:** What PCM formats/sample rates does AppleVirtIOSound negotiate?
   Likely 44.1kHz/48kHz 16-bit or 32-bit float stereo, but must verify through testing.

3. **Event virtqueue usage:** Does AppleVirtIOSound poll eventq? If so, what events must we
   generate?

4. **Multiple streams:** Can we expose more than 2 streams (e.g., multi-channel output)?
   The config space `streams` field supports this, but driver support is unknown.

5. **Feature bit requirements:** Does AppleVirtIOSound require VIRTIO_SND_F_CTLS or any
   other specific feature bits?

6. **Interrupt coalescing:** How does AppleVirtIOSound expect interrupt delivery? Per-buffer
   or batched?

---

## Sources

### Apple Documentation
- [VZVirtioSoundDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtiosounddeviceconfiguration)
- [Audio - Virtualization Framework](https://developer.apple.com/documentation/virtualization/audio)
- [Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [Create audio drivers with DriverKit - WWDC21](https://developer.apple.com/videos/play/wwdc2021/10190/)
- [Securely extending the kernel in macOS](https://support.apple.com/guide/security/securely-extending-the-kernel-sec8e454101b/web)
- [AudioDriverKit Extension for Virtual Devices - Apple Forums](https://developer.apple.com/forums/thread/682035)

### Virtio Specification
- [OASIS Virtio v1.2 Specification (Sound Device: Section 5.14)](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
- [QEMU VirtIO Sound Documentation](https://www.qemu.org/docs/master/system/devices/virtio/virtio-snd.html)
- [QEMU PCI IDs for Virtio](https://www.qemu.org/docs/master/specs/pci-ids.html)

### Community / Third-Party
- [UTM Issue #6404 - Virtio sound support](https://github.com/utmapp/UTM/issues/6404)
- [What happens when you run a macOS VM on Apple Silicon - Eclectic Light](https://eclecticlight.co/2023/10/21/what-happens-when-you-run-a-macos-vm-on-apple-silicon/)
- [OSX-KVM Audio Notes](https://github.com/kholia/OSX-KVM/blob/master/notes.md)
- [Running Third-Party Kexts in VZ macOS VMs](https://gist.github.com/steven-michaud/fda019a4ae2df3a9295409053a53a65c)
- [AppleHDA removed from macOS Tahoe](https://github.com/perez987/AppleHDA-back-on-macOS-26-Tahoe)
- [libASPL - AudioServerPlugin library](https://github.com/gavv/libASPL)
- [BlackHole Virtual Audio Driver](https://github.com/ExistentialAudio/BlackHole)
- [Phil Jordan - macOS Guest Device Drivers](http://www.philjordan.eu/osx-virt/)
