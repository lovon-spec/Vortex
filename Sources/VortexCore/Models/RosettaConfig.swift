// RosettaConfig.swift — Rosetta 2 translation layer configuration.
// VortexCore

/// Configuration for Rosetta 2 translation inside Linux ARM64 guests.
///
/// When enabled, x86_64 Linux binaries can run inside the ARM64 guest VM
/// using Apple's Rosetta translation layer exposed via a VirtioFS share.
public struct RosettaConfig: Codable, Sendable, Hashable {
    /// Whether Rosetta translation is enabled for this VM.
    public var enabled: Bool

    /// The mount tag used for the Rosetta VirtioFS share inside the guest.
    /// Defaults to `"rosetta"`.
    public var mountTag: String

    public init(enabled: Bool = false, mountTag: String = "rosetta") {
        self.enabled = enabled
        self.mountTag = mountTag
    }

    /// Rosetta enabled with default mount tag.
    public static let enabled = RosettaConfig(enabled: true)

    /// Rosetta disabled.
    public static let disabled = RosettaConfig(enabled: false)
}
