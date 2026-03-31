// SharedFolderConfig.swift — VirtioFS shared folder mount configuration.
// VortexCore

import Foundation

/// A VirtioFS directory share between host and guest.
public struct SharedFolderConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID

    /// Tag used to identify this share inside the guest (mount point name).
    /// Example: `"workspace"` would be mounted as `/Volumes/My Shared Files/workspace` on macOS guests.
    public var tag: String

    /// Absolute path on the host filesystem to the shared directory.
    public var hostPath: String

    /// Whether the guest has write access to this share.
    public var readOnly: Bool

    public init(
        id: UUID = UUID(),
        tag: String,
        hostPath: String,
        readOnly: Bool = false
    ) {
        self.id = id
        self.tag = tag
        self.hostPath = hostPath
        self.readOnly = readOnly
    }
}
