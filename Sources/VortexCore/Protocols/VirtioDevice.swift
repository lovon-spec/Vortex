// VirtioDevice.swift — Base protocol for all virtio device emulations.
// VortexCore

import Foundation

/// Identifies a virtio device by its type within the PCI topology.
public enum VirtioDeviceType: String, Codable, Sendable, CaseIterable {
    case network
    case block
    case console
    case entropy
    case balloon
    case filesystem
    case gpu
    case sound
    case input
    case socket
}

/// Base protocol for all emulated virtio devices.
///
/// Each virtio device goes through a lifecycle of configuration, activation
/// (when the guest driver negotiates features and sets up virtqueues), and
/// teardown. Conforming types implement the device-specific behavior.
public protocol VirtioDevice: AnyObject, Sendable {

    /// The virtio device type identifier.
    var deviceType: VirtioDeviceType { get }

    /// A unique identifier for this device instance within the VM.
    var deviceID: UUID { get }

    /// Human-readable label (e.g. "virtio-net-0", "virtio-blk-boot").
    var label: String { get }

    /// Whether the device has been activated by the guest driver.
    var isActivated: Bool { get async }

    /// Called when the VM is starting up to allow the device to prepare
    /// its internal state and allocate resources.
    ///
    /// - Throws: `VortexError.deviceConfigurationFailed` on failure.
    func configure() async throws

    /// Called when the guest driver has completed feature negotiation
    /// and the device should begin processing I/O.
    ///
    /// - Throws: `VortexError.deviceActivationFailed` on failure.
    func activate() async throws

    /// Called when the VM is shutting down. The device should release
    /// all host resources (file handles, memory mappings, etc.).
    func reset() async throws
}
