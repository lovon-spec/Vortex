// SnapshotMetadata.swift — Metadata for a VM state snapshot.
// VortexCore

import Foundation

/// Metadata describing a saved VM snapshot.
///
/// The actual snapshot data (memory image, disk state) is stored externally;
/// this struct holds only the identifying metadata and bookkeeping fields.
public struct SnapshotMetadata: Codable, Sendable, Hashable, Identifiable {
    /// Unique identifier for this snapshot.
    public var id: UUID

    /// The VM configuration ID this snapshot belongs to.
    public var vmID: UUID

    /// User-provided name for the snapshot.
    public var name: String

    /// Optional user-provided description.
    public var descriptionText: String?

    /// When the snapshot was created.
    public var createdAt: Date

    /// The VM state at the time the snapshot was taken.
    public var vmStateAtCapture: VMState

    /// Size of the snapshot data on disk, in bytes. May be `nil` if not yet calculated.
    public var sizeBytes: UInt64?

    /// The parent snapshot ID, if this snapshot was taken from another snapshot.
    /// Forms a tree of snapshots.
    public var parentSnapshotID: UUID?

    /// Absolute path to the snapshot data on the host filesystem.
    public var storagePath: String

    public init(
        id: UUID = UUID(),
        vmID: UUID,
        name: String,
        descriptionText: String? = nil,
        createdAt: Date = Date(),
        vmStateAtCapture: VMState = .paused,
        sizeBytes: UInt64? = nil,
        parentSnapshotID: UUID? = nil,
        storagePath: String
    ) {
        self.id = id
        self.vmID = vmID
        self.name = name
        self.descriptionText = descriptionText
        self.createdAt = createdAt
        self.vmStateAtCapture = vmStateAtCapture
        self.sizeBytes = sizeBytes
        self.parentSnapshotID = parentSnapshotID
        self.storagePath = storagePath
    }

    // MARK: - Convenience

    /// Formatted size string (e.g. "1.2 GiB"). Returns "Unknown" if size is nil.
    public var sizeDisplayString: String {
        guard let bytes = sizeBytes else { return "Unknown" }
        let gib = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gib >= 1.0 {
            return String(format: "%.1f GiB", gib)
        }
        let mib = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MiB", mib)
    }
}
