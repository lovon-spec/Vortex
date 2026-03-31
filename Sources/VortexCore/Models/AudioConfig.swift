// AudioConfig.swift — Per-VM audio device routing configuration.
// VortexCore

/// Per-VM audio configuration controlling which host audio devices the VM uses.
///
/// Each VM can independently target specific CoreAudio devices for both input and
/// output, enabling scenarios like routing one VM through BlackHole for DAW capture
/// while another VM uses the default speakers.
public struct AudioConfig: Codable, Sendable, Hashable {
    /// Whether audio is enabled for this VM.
    public var enabled: Bool

    /// The host audio output device (speakers/virtual device) the VM routes to.
    /// When `nil`, the system default output device is used.
    public var output: AudioEndpointConfig?

    /// The host audio input device (microphone/virtual device) the VM captures from.
    /// When `nil`, the system default input device is used.
    public var input: AudioEndpointConfig?

    public init(
        enabled: Bool = true,
        output: AudioEndpointConfig? = nil,
        input: AudioEndpointConfig? = nil
    ) {
        self.enabled = enabled
        self.output = output
        self.input = input
    }

    /// Audio disabled entirely.
    public static let disabled = AudioConfig(enabled: false)

    /// Audio enabled using system default devices for both input and output.
    public static let systemDefaults = AudioConfig(enabled: true)
}

/// Identifies a specific CoreAudio host device that a VM endpoint is routed to.
public struct AudioEndpointConfig: Codable, Sendable, Hashable {
    /// The CoreAudio device UID (persistent across reboots).
    /// Example: `"BlackHole16ch_UID"`, `"BuiltInSpeakerDevice"`.
    public var hostDeviceUID: String

    /// Human-readable display name for the device.
    /// Example: `"BlackHole 16ch"`, `"MacBook Pro Speakers"`.
    public var hostDeviceName: String

    public init(hostDeviceUID: String, hostDeviceName: String) {
        self.hostDeviceUID = hostDeviceUID
        self.hostDeviceName = hostDeviceName
    }
}
