// PersistenceStore.swift — VM configuration CRUD persistence protocol.
// VortexCore

import Foundation

/// Protocol for persisting VM configurations and snapshot metadata.
///
/// Implementations might store data as JSON files on disk, in a SQLite
/// database, or in CloudKit. The protocol is intentionally simple --
/// a CRUD interface over `VMConfiguration` and `SnapshotMetadata`.
public protocol PersistenceStore: AnyObject, Sendable {

    // MARK: - VM Configurations

    /// Persists a new or updated VM configuration.
    ///
    /// If a configuration with the same `id` already exists, it is overwritten.
    ///
    /// - Parameter configuration: The VM configuration to save.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func save(_ configuration: VMConfiguration) async throws

    /// Loads a VM configuration by its identifier.
    ///
    /// - Parameter id: The unique identifier of the VM.
    /// - Returns: The configuration, or `nil` if no VM with that ID exists.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func load(id: UUID) async throws -> VMConfiguration?

    /// Returns all stored VM configurations.
    ///
    /// - Returns: An array of all VM configurations, sorted by `modifiedAt` descending.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func listAll() async throws -> [VMConfiguration]

    /// Deletes a VM configuration by its identifier.
    ///
    /// This does NOT delete the VM's disk images or snapshot data on disk.
    /// Callers are responsible for cleaning up associated resources.
    ///
    /// - Parameter id: The unique identifier of the VM to delete.
    /// - Throws: `VortexError.vmNotFound` if no VM with that ID exists.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func delete(id: UUID) async throws

    /// Checks whether a configuration with the given ID exists.
    ///
    /// - Parameter id: The unique identifier to check.
    /// - Returns: `true` if a configuration with that ID exists.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func exists(id: UUID) async throws -> Bool

    // MARK: - Snapshots

    /// Persists snapshot metadata.
    ///
    /// - Parameter snapshot: The snapshot metadata to save.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func saveSnapshot(_ snapshot: SnapshotMetadata) async throws

    /// Returns all snapshots belonging to a VM, ordered by creation date descending.
    ///
    /// - Parameter vmID: The VM identifier to list snapshots for.
    /// - Returns: An array of snapshot metadata.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func listSnapshots(forVM vmID: UUID) async throws -> [SnapshotMetadata]

    /// Deletes a snapshot's metadata by its identifier.
    ///
    /// This does NOT delete the snapshot data on disk. Callers are
    /// responsible for removing the snapshot files at `storagePath`.
    ///
    /// - Parameter id: The snapshot identifier.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    func deleteSnapshot(id: UUID) async throws
}
