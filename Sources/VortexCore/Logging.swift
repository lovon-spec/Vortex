// Logging.swift — Structured logging via os.Logger for all Vortex modules.
// VortexCore
//
// Provides a centralized, categorized set of os.Logger instances. All modules
// import VortexCore and use these loggers instead of print(). Each category
// maps to a subsystem+category pair visible in Console.app and `log stream`.
//
// Usage:
//   VortexLog.audio.info("AudioRouter configured: \(format)")
//   VortexLog.bridge.debug("PCM_OUTPUT: \(byteCount) bytes")
//   VortexLog.vm.error("Failed to create vCPU: \(status)")
//
// Viewing logs:
//   log stream --predicate 'subsystem == "com.vortex"' --level debug

import os

/// Centralized os.Logger instances for structured logging across all Vortex modules.
///
/// Each static property targets a specific functional area. Use the appropriate
/// logger for the code you are instrumenting:
/// - `audio`: CoreAudio routing, AudioUnit lifecycle, format conversion.
/// - `vm`: VM lifecycle, vCPU events, memory mapping, device emulation.
/// - `bridge`: Vsock/TCP audio transport between guest and host.
/// - `gui`: SwiftUI application events, window management.
/// - `cli`: Command-line interface operations.
/// - `hv`: Hypervisor.framework operations, low-level VMM events.
/// - `boot`: Firmware loading, IPSW extraction, boot chain.
/// - `persistence`: VM configuration save/load, repository operations.
public enum VortexLog {
    /// Audio routing: AudioUnit, AudioQueue, ring buffers, format negotiation.
    public static let audio = Logger(subsystem: "com.vortex", category: "audio")

    /// VM lifecycle: create, start, stop, pause, state transitions.
    public static let vm = Logger(subsystem: "com.vortex", category: "vm")

    /// Vsock/TCP audio bridge: guest-host PCM transport, wire protocol.
    public static let bridge = Logger(subsystem: "com.vortex", category: "bridge")

    /// GUI application: window management, view model state.
    public static let gui = Logger(subsystem: "com.vortex", category: "gui")

    /// CLI operations: command parsing, user-facing status.
    public static let cli = Logger(subsystem: "com.vortex", category: "cli")

    /// Hypervisor.framework: vCPU run loops, exits, MMIO, GIC, timers.
    public static let hv = Logger(subsystem: "com.vortex", category: "hv")

    /// Boot/firmware: IPSW extraction, UEFI loading, device tree.
    public static let boot = Logger(subsystem: "com.vortex", category: "boot")

    /// Persistence: VM config serialization, repository I/O.
    public static let persistence = Logger(subsystem: "com.vortex", category: "persistence")
}
