// ClipboardConfig.swift — Clipboard sharing configuration.
// VortexCore

/// Configuration for clipboard sharing between host and guest.
///
/// Clipboard sharing is supported only on macOS guests via the Virtualization
/// framework's spice agent channel.
public struct ClipboardConfig: Codable, Sendable, Hashable {
    /// Whether clipboard sharing is enabled.
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// Clipboard sharing enabled.
    public static let enabled = ClipboardConfig(enabled: true)

    /// Clipboard sharing disabled.
    public static let disabled = ClipboardConfig(enabled: false)
}
