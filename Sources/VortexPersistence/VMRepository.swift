// VMRepository.swift — CRUD operations for VM configurations on disk.
// VortexPersistence

import Foundation
import VortexCore

/// Provides CRUD operations for `VMConfiguration` objects, persisted as
/// `config.json` files inside VM bundle directories.
///
/// `VMRepository` works in concert with `VMFileManager` -- it reads and
/// writes the configuration JSON within bundles that `VMFileManager` creates
/// and manages.
///
/// ## Threading
///
/// All methods are synchronous and perform file I/O on the caller's thread.
/// The class is `Sendable`; callers should dispatch to a background queue
/// when invoking from the main thread.
public final class VMRepository: Sendable {

    // MARK: - Properties

    /// The file manager used for bundle directory operations.
    public let fileManager: VMFileManager

    // MARK: - Init

    /// Creates a repository backed by the given file manager.
    ///
    /// - Parameter fileManager: The `VMFileManager` controlling bundle locations.
    ///   Defaults to a new instance using the standard Application Support path.
    public init(fileManager: VMFileManager = VMFileManager()) {
        self.fileManager = fileManager
    }

    // MARK: - Save

    /// Persists a VM configuration to its bundle's `config.json`.
    ///
    /// If the VM bundle does not exist yet, it is created. If it already
    /// exists, only the `config.json` file is overwritten.
    ///
    /// - Parameter config: The VM configuration to save.
    /// - Throws: `VortexError.persistenceFailed` on encoding or I/O failure.
    public func save(_ config: VMConfiguration) throws {
        let bundlePath = fileManager.vmBundlePath(for: config.id)

        // Create the bundle if it does not exist.
        if !fileManager.bundleExists(for: config.id) {
            try fileManager.createVMBundle(for: config)
            return
        }

        // Bundle exists -- just overwrite config.json.
        let configPath = fileManager.configFilePath(for: config.id)
        do {
            let data = try VMConfigCodec.encode(config)
            try data.write(to: configPath, options: .atomic)
        } catch let error as VortexError {
            throw error
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to save config at \(bundlePath.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Load

    /// Loads a VM configuration from its bundle's `config.json`.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Returns: The deserialized `VMConfiguration`.
    /// - Throws: `VortexError.vmNotFound` if no bundle exists for the given ID.
    /// - Throws: `VortexError.persistenceFailed` on decoding or I/O failure.
    public func load(id: UUID) throws -> VMConfiguration {
        let configPath = fileManager.configFilePath(for: id)

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw VortexError.vmNotFound(id: id)
        }

        do {
            let data = try Data(contentsOf: configPath)
            return try VMConfigCodec.decode(VMConfiguration.self, from: data)
        } catch let error as VortexError {
            throw error
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to load config for VM \(id): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Load all

    /// Loads all VM configurations from all bundles in the base directory.
    ///
    /// Bundles whose `config.json` cannot be decoded are silently skipped
    /// and a diagnostic message is printed to stderr.
    ///
    /// - Returns: An array of `VMConfiguration` objects sorted by `modifiedAt`
    ///   descending (most recently modified first).
    /// - Throws: `VortexError.persistenceFailed` on failure to list bundles.
    public func loadAll() throws -> [VMConfiguration] {
        let bundles = try fileManager.listVMBundles()

        var configurations: [VMConfiguration] = []
        configurations.reserveCapacity(bundles.count)

        for bundleURL in bundles {
            let configURL = bundleURL.appendingPathComponent(VMFileManager.configFileName)
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: configURL)
                let config = try VMConfigCodec.decode(VMConfiguration.self, from: data)
                configurations.append(config)
            } catch {
                // Log but don't fail the entire load -- other VMs should still appear.
                fputs(
                    "warning: Skipping corrupt VM bundle at \(bundleURL.path): \(error.localizedDescription)\n",
                    stderr
                )
            }
        }

        // Sort by modification date, most recent first.
        configurations.sort { $0.modifiedAt > $1.modifiedAt }

        return configurations
    }

    // MARK: - Delete

    /// Deletes a VM's bundle, including its configuration, disks, and all
    /// associated data.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Throws: `VortexError.vmNotFound` if no bundle exists.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    public func delete(id: UUID) throws {
        try fileManager.deleteVMBundle(id: id)
    }

    // MARK: - Update

    /// Updates an existing VM configuration, bumping `modifiedAt` to now.
    ///
    /// - Parameter config: The updated VM configuration. Its `id` must match
    ///   an existing bundle.
    /// - Throws: `VortexError.vmNotFound` if no bundle exists for this ID.
    /// - Throws: `VortexError.persistenceFailed` on encoding or I/O failure.
    public func update(_ config: VMConfiguration) throws {
        guard fileManager.bundleExists(for: config.id) else {
            throw VortexError.vmNotFound(id: config.id)
        }

        let updated = config.touchingModifiedDate()
        let configPath = fileManager.configFilePath(for: config.id)

        do {
            let data = try VMConfigCodec.encode(updated)
            try data.write(to: configPath, options: .atomic)
        } catch let error as VortexError {
            throw error
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to update config for VM \(config.id): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Exists

    /// Checks whether a configuration with the given ID is persisted.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Returns: `true` if a bundle with a valid `config.json` exists.
    public func exists(id: UUID) -> Bool {
        let configPath = fileManager.configFilePath(for: id)
        return FileManager.default.fileExists(atPath: configPath.path)
    }
}

// MARK: - PersistenceStore conformance

/// Async wrapper conforming to the `PersistenceStore` protocol from VortexCore.
///
/// This adapter bridges the synchronous `VMRepository` and `SnapshotRepository`
/// into the async protocol interface expected by higher-level code.
public final class DiskPersistenceStore: PersistenceStore, @unchecked Sendable {

    private let vmRepository: VMRepository
    private let snapshotRepository: SnapshotRepository

    /// Creates a `DiskPersistenceStore` using the given repositories.
    ///
    /// - Parameters:
    ///   - vmRepository: Repository for VM configuration CRUD.
    ///   - snapshotRepository: Repository for snapshot metadata CRUD.
    public init(
        vmRepository: VMRepository = VMRepository(),
        snapshotRepository: SnapshotRepository? = nil
    ) {
        self.vmRepository = vmRepository
        self.snapshotRepository = snapshotRepository ?? SnapshotRepository(
            fileManager: vmRepository.fileManager
        )
    }

    // MARK: - VM Configurations

    public func save(_ configuration: VMConfiguration) async throws {
        try vmRepository.save(configuration)
    }

    public func load(id: UUID) async throws -> VMConfiguration? {
        guard vmRepository.exists(id: id) else { return nil }
        return try vmRepository.load(id: id)
    }

    public func listAll() async throws -> [VMConfiguration] {
        try vmRepository.loadAll()
    }

    public func delete(id: UUID) async throws {
        try vmRepository.delete(id: id)
    }

    public func exists(id: UUID) async throws -> Bool {
        vmRepository.exists(id: id)
    }

    // MARK: - Snapshots

    public func saveSnapshot(_ snapshot: SnapshotMetadata) async throws {
        try snapshotRepository.saveSnapshotMetadata(snapshot)
    }

    public func listSnapshots(forVM vmID: UUID) async throws -> [SnapshotMetadata] {
        try snapshotRepository.listSnapshots(for: vmID)
    }

    public func deleteSnapshot(id: UUID) async throws {
        // Snapshot deletion requires knowing the vmID. We search all VMs.
        let bundles = try vmRepository.fileManager.listVMBundles()
        for bundleURL in bundles {
            let vmIDString = bundleURL.deletingPathExtension().lastPathComponent
            guard let vmID = UUID(uuidString: vmIDString) else { continue }
            let snapshots = try snapshotRepository.listSnapshots(for: vmID)
            if snapshots.contains(where: { $0.id == id }) {
                try snapshotRepository.deleteSnapshot(id, for: vmID)
                return
            }
        }
        throw VortexError.snapshotFailed(reason: "Snapshot \(id) not found in any VM bundle.")
    }
}
