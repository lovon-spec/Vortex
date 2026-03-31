// VMIdentity.swift — VM display name, icon, and metadata.
// VortexCore

/// Human-facing identity information for a virtual machine.
public struct VMIdentity: Codable, Sendable, Hashable {
    /// User-assigned display name.
    public var name: String

    /// Optional icon name or SF Symbol identifier for UI display.
    public var iconName: String?

    /// Optional user-provided notes or description.
    public var notes: String?

    /// Optional tags for organization and filtering.
    public var tags: [String]

    public init(
        name: String,
        iconName: String? = nil,
        notes: String? = nil,
        tags: [String] = []
    ) {
        self.name = name
        self.iconName = iconName
        self.notes = notes
        self.tags = tags
    }
}
