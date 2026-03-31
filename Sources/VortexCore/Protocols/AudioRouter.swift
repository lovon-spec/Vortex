// AudioRouter.swift — Per-VM audio routing protocol.
// VortexCore

import Foundation

/// Describes a host audio device discovered via CoreAudio.
public struct HostAudioDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: String { uid }

    /// CoreAudio device UID (persistent identifier).
    public var uid: String

    /// Human-readable device name.
    public var name: String

    /// Whether this device supports audio output (playback).
    public var supportsOutput: Bool

    /// Whether this device supports audio input (capture).
    public var supportsInput: Bool

    /// Number of output channels available.
    public var outputChannelCount: Int

    /// Number of input channels available.
    public var inputChannelCount: Int

    /// The nominal sample rate of the device.
    public var sampleRate: Double

    public init(
        uid: String,
        name: String,
        supportsOutput: Bool,
        supportsInput: Bool,
        outputChannelCount: Int = 0,
        inputChannelCount: Int = 0,
        sampleRate: Double = 48000.0
    ) {
        self.uid = uid
        self.name = name
        self.supportsOutput = supportsOutput
        self.supportsInput = supportsInput
        self.outputChannelCount = outputChannelCount
        self.inputChannelCount = inputChannelCount
        self.sampleRate = sampleRate
    }
}

/// Protocol for managing per-VM audio device routing.
///
/// Each VM can independently route its audio output and input to specific
/// host CoreAudio devices. This enables use cases like capturing a single
/// VM's audio via a virtual device (e.g. BlackHole) while other VMs
/// play through speakers.
public protocol AudioRouter: AnyObject, Sendable {

    /// Enumerates all available host audio devices.
    ///
    /// - Returns: An array of discovered host audio devices.
    /// - Throws: `VortexError.audioDeviceNotFound` if enumeration fails.
    func availableDevices() async throws -> [HostAudioDevice]

    /// Applies the given audio configuration to a running VM.
    ///
    /// If the VM is running, audio streams are reconfigured on the fly.
    /// If the VM is stopped, the configuration is stored for the next start.
    ///
    /// - Parameters:
    ///   - config: The desired audio configuration.
    ///   - vmID: The VM to apply the routing to.
    /// - Throws: `VortexError.audioRoutingFailed` if the device is unavailable.
    func applyConfiguration(_ config: AudioConfig, forVM vmID: UUID) async throws

    /// Returns the currently active audio configuration for a VM.
    ///
    /// - Parameter vmID: The VM identifier.
    /// - Returns: The current audio configuration, or `nil` if the VM has no audio.
    func currentConfiguration(forVM vmID: UUID) async -> AudioConfig?

    /// Returns the default system output device.
    ///
    /// - Returns: The default output device.
    /// - Throws: `VortexError.audioDeviceNotFound` if no output device is available.
    func defaultOutputDevice() async throws -> HostAudioDevice

    /// Returns the default system input device.
    ///
    /// - Returns: The default input device.
    /// - Throws: `VortexError.audioDeviceNotFound` if no input device is available.
    func defaultInputDevice() async throws -> HostAudioDevice
}
