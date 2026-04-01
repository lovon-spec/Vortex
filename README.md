# Vortex

**Open-source macOS VM hypervisor with per-VM audio device routing.**

Vortex runs macOS guests on Apple Silicon and lets you route each VM's audio to
a different host device -- something no existing macOS virtualizer supports.
Route one VM through BlackHole for DAW capture, another through studio monitors,
and a third through headphones, all without touching your host's default audio
settings.

---

## The Problem

Every macOS virtualizer today -- Parallels, UTM, VirtualBuddy, Tart -- sends
all VM audio to the host's default output device. If you run multiple VMs, they
all share the same speakers. There is no way to:

- Route VM A's audio to a specific audio interface while VM B goes to headphones.
- Capture a single VM's audio output into a DAW without capturing everything.
- Feed a dedicated microphone into one VM while another VM uses a different input.

Apple's Virtualization.framework provides `VZVirtioSoundDeviceConfiguration`, but
it hard-codes audio to the system default device with no API to change the target.

Vortex solves this by bypassing VZ's built-in audio entirely and building a
dedicated audio transport between each guest and the host, with full per-VM
device targeting.

---

## Key Features

- **macOS guest VMs on Apple Silicon** via Virtualization.framework
- **Per-VM audio output routing** to any host CoreAudio device
- **Per-VM audio input routing** from any host CoreAudio device
- **No host defaults affected** -- system audio settings are never modified
- **Native SwiftUI GUI** with VM display, audio device selection, and persistence
- **Headless CLI** for scripted and server workflows
- **Guest tools** (HAL AudioServerPlugin + daemon) packaged as a standard .pkg
- **VM lifecycle management** -- create, install from IPSW, start, stop
- **Device hot-swap** -- change audio routing while a VM is running
- **Latency instrumentation** -- built-in measurement of the audio pipeline
- **Audio format conversion** -- automatic sample rate and channel mapping

---

## Architecture

Vortex uses a vsock audio bridge to tunnel PCM data between the guest and host,
bypassing Virtualization.framework's locked-down audio path.

```
macOS Guest VM                              macOS Host
+---------------------------+               +---------------------------+
|                           |               |                           |
|  App plays/records audio  |               |  VsockAudioBridge         |
|          |                |               |      |          |         |
|          v                |               |      v          v         |
|  "Vortex Audio" device    |               |  AudioOutput  AudioInput  |
|  (HAL AudioServerPlugin)  |               |  Unit         Unit        |
|          |                |               |      |          |         |
|   POSIX shared memory     |               |  AudioRingBuffer (x2)    |
|          |                |               |      |          |         |
|  VortexAudioDaemon        |    TCP/vsock  |  AudioRouter              |
|          +--------------------->>---------+      |          |         |
|                           |               |      v          v         |
+---------------------------+               |  BlackHole   USB Mic      |
                                            |  (or any     (or any     |
                                            |   device)     device)    |
                                            +---------------------------+
```

**Data flow (output):**
1. Guest application plays audio through CoreAudio.
2. The "Vortex Audio" HAL plugin captures PCM in a lock-free ring buffer.
3. The VortexAudioDaemon reads from shared memory and sends over TCP (vsock port 5198).
4. The host-side VsockAudioBridge receives PCM and writes to an AudioRingBuffer.
5. An AudioOutputUnit render callback (real-time thread) pulls from the ring buffer.
6. Audio plays on the targeted host device -- not the system default.

**Data flow (input):** The reverse path. The host AudioInputUnit captures from
a specific device, the bridge sends PCM to the guest daemon, and the HAL plugin
provides it to guest applications as microphone input.

---

## Quick Start

### 1. Build

```bash
git clone https://github.com/vortex-vm/Vortex.git
cd Vortex
make                    # Build debug + sign + guest tools
```

### 2. Create a VM

```bash
./sign-and-run.sh create-vm --name "My VM" --cpu 4 --memory 8192 --disk 64
```

### 3. Install macOS

```bash
# Automatically downloads the latest compatible IPSW from Apple:
./sign-and-run.sh install-macos --vm <uuid>

# Or use a local IPSW:
./sign-and-run.sh install-macos --vm <uuid> --ipsw /path/to/macOS.ipsw
```

### 4. Start the VM with GUI

```bash
./sign-and-run.sh --gui
```

### 5. Install Guest Tools

Copy `GuestTools/build/VortexGuestTools.pkg` into the VM (via shared folder or
drag-and-drop), then inside the guest:

```bash
sudo installer -pkg VortexGuestTools.pkg -target /
```

This installs:
- `/Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver` -- the virtual audio device
- `/usr/local/bin/VortexAudioDaemon` -- the vsock-to-HAL bridge daemon
- `/Library/LaunchDaemons/com.vortex.audiodaemon.plist` -- auto-start on boot

The installer restarts `coreaudiod` automatically. A "Vortex Audio" device
will appear in the guest's Sound preferences.

### 6. Route Audio

In the GUI, open Audio Settings and select the target host device for output
and input. Or from the CLI:

```bash
./sign-and-run.sh start-vm --vm <uuid> \
    --audio-output "BlackHole 16ch" \
    --audio-input "BlackHole 2ch"
```

---

## Requirements

- **macOS 14 Sonoma** or later (deployment target: macOS 14.0)
- **Apple Silicon** (M1 or later)
- **Physical hardware** -- Hypervisor.framework does not support nested virtualization
- **Xcode Command Line Tools** -- `xcode-select --install`
- A **virtual audio device** such as [BlackHole](https://github.com/ExistentialAudio/BlackHole) for routing (optional -- you can also target any physical device)

---

## Project Structure

| Module | Description |
|---|---|
| **VortexCore** | Pure Swift models, protocols, errors. Zero framework dependencies. |
| **VortexHV** | Hypervisor.framework VMM: vCPU threads, memory, GIC, timer, PCI, MMIO. |
| **VortexAudio** | Per-VM CoreAudio routing: device enumeration, AudioUnit, ring buffers, format conversion. |
| **VortexDevices** | Virtual device emulation: virtio-blk/net/gpu/snd/console, PL011, RTC. |
| **VortexBoot** | Firmware loading: UEFI for Linux, macOS boot chain via VZ. |
| **VortexPersistence** | VM bundle on-disk format, JSON config, snapshot metadata. |
| **VortexVZ** | Virtualization.framework VM manager and vsock audio bridge. |
| **VortexInterception** | Track A experiment: fishhook-based CoreAudio interception. |
| **VortexGUI** | SwiftUI application: VM display, audio settings, lifecycle controls. |
| **VortexCLI** | Headless CLI via swift-argument-parser. |
| **CFishHook** | C library for Mach-O lazy symbol rebinding. |
| **GuestTools/** | Guest-side HAL AudioServerPlugin (C) and audio daemon (Swift). |

---

## Building

```bash
make                    # Debug build, sign, and build guest tools
make release            # Release build (optimized) + sign
make guest-tools        # Build guest tools .pkg only
make app                # Create .build/Vortex.app bundle (release, signed)
make dmg                # Create Vortex.dmg with app + guest tools
make clean              # Remove all build artifacts
```

To build individual Swift targets:

```bash
swift build                                     # All targets, debug
swift build -c release                          # All targets, release
swift test --filter VortexAudioTests            # Run audio tests
swift test --filter VortexVZTests               # Run VZ tests
```

**Code signing:** The `make sign` target applies the entitlements in
`Vortex.entitlements` (virtualization, hypervisor, network client) using ad-hoc
signing. For distribution, set `SIGNING_ID` to your Developer ID:

```bash
make release SIGNING_ID="Developer ID Application: Your Name (TEAM_ID)"
```

---

## CLI Reference

```
OVERVIEW: Vortex Virtual Machine Monitor -- command-line interface.

SUBCOMMANDS:
  create-vm               Create a new macOS virtual machine.
  install-macos           Install macOS into a VM from an IPSW.
  start-vm                Start a macOS VM with vsock audio bridge.
  list-vms                List all virtual machines.
  measure-latency         Measure audio pipeline latency.
  test-audio-route        Test host-side audio routing with a sine wave tone.
  test-audio-intercept    Track A: test whether VZ audio runs in-process.
```

### Examples

```bash
# Create a VM with 4 CPUs, 8 GB RAM, 64 GB disk
vortex create-vm --name "Dev VM" --cpu 4 --memory 8192 --disk 64

# Install macOS (downloads latest IPSW automatically)
vortex install-macos --vm <uuid>

# Start with audio routed to specific devices
vortex start-vm --vm <uuid> --audio-output "BlackHole 16ch" --audio-input "USB Microphone"

# List all VMs
vortex list-vms

# Test audio routing without a VM (plays a 440 Hz tone)
vortex test-audio-route --device "BlackHole 16ch" --duration 5

# Measure audio pipeline latency
vortex measure-latency --device "BlackHole 16ch" --duration 10
```

---

## Guest Tools Installation

The guest tools package (`VortexGuestTools.pkg`) must be installed inside each
macOS guest VM to enable per-VM audio routing.

**What it installs:**

| Path | Component |
|---|---|
| `/Library/Audio/Plug-Ins/HAL/VortexAudioPlugin.driver` | CoreAudio HAL plugin -- registers "Vortex Audio" device |
| `/usr/local/bin/VortexAudioDaemon` | Bridge daemon -- connects HAL plugin to host via TCP/vsock |
| `/Library/LaunchDaemons/com.vortex.audiodaemon.plist` | LaunchDaemon plist for auto-start |

**Installation steps:**

1. Build the package: `make guest-tools` (output: `GuestTools/build/VortexGuestTools.pkg`)
2. Copy the .pkg into the guest VM via shared folder or drag-and-drop.
3. Inside the guest, run: `sudo installer -pkg VortexGuestTools.pkg -target /`
4. The postinstall script restarts `coreaudiod` and loads the daemon.
5. Verify: open System Settings > Sound -- "Vortex Audio" should appear as a device.

**How it works:**

The HAL plugin runs inside `coreaudiod` on a real-time audio thread. It reads
and writes PCM samples through a POSIX shared memory ring buffer
(`/dev/shm/vortex_audio`). The daemon is the non-real-time side: it polls the
shared memory region and transfers audio over a TCP connection to the host's
VsockAudioBridge.

---

## Known Limitations

- **macOS 2-VM limit.** Apple Silicon enforces a maximum of two concurrent macOS
  VMs at the kernel level. This is an Apple platform restriction, not a Vortex
  limitation.

- **Guest tools require manual installation.** There is no automated injection
  mechanism. The .pkg must be copied into the VM and installed by the user.

- **TCC microphone permission.** For audio input routing, the host application
  must be launched from an .app bundle (not a bare binary) so macOS presents the
  microphone permission dialog. Use `./sign-and-run.sh --gui` or `make app` to
  ensure proper TCC handling.

- **Audio transport latency.** The vsock-to-TCP bridge adds latency compared to
  native audio. Measured at approximately 5-15ms one-way at 48 kHz depending on
  buffer configuration. Adequate for general use and DAW capture; not suitable
  for real-time instrument monitoring.

- **No Linux/Windows guest audio yet.** The current guest tools target macOS
  only. The host-side audio routing infrastructure is guest-agnostic and can
  support other operating systems with appropriate guest drivers.

---

## Documentation

The `docs/` directory contains detailed technical analysis:

| Document | Description |
|---|---|
| [macos-guest-audio-analysis.md](docs/macos-guest-audio-analysis.md) | Audio device driver landscape on macOS ARM64 (virtio-snd, HDA, AC97) |
| [macos-boot-analysis.md](docs/macos-boot-analysis.md) | macOS guest boot chain feasibility on Apple Silicon |
| [vmapple-device-model.md](docs/vmapple-device-model.md) | Apple's private vmapple platform device model documentation |

---

## Entitlements

Vortex requires the following entitlements (defined in `Vortex.entitlements`):

| Entitlement | Purpose |
|---|---|
| `com.apple.security.virtualization` | Virtualization.framework access for macOS VM management |
| `com.apple.security.hypervisor` | Hypervisor.framework access for low-level VM control |
| `com.apple.security.network.client` | TCP connections for the vsock audio bridge |

---

## License

MIT License. See [LICENSE](LICENSE) for details.

Copyright 2024-2026 Vortex Authors.

---

## Contributing

Contributions are welcome. Before starting significant work, please open an
issue to discuss the approach.

**Guidelines:**

- Swift 5.9+, macOS 14+ deployment target.
- All public APIs must have documentation comments.
- No force unwraps (`!`) in production code. Use typed errors.
- Audio callbacks must be RT-safe: no allocations, no locks, no syscalls.
- Run `swift build` and `swift test` before submitting.
- Guest tools (C code) must compile with `-Wall -Werror`.
