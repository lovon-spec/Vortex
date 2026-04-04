// SnapshotRepository.swift — Snapshot metadata persistence and APFS clonefile operations.
// VortexPersistence

import Foundation
import VortexCore

// MARK: - clonefile(2) import

/// Import the `clonefile(2)` syscall from Darwin for APFS copy-on-write file cloning.
///
/// On APFS, `clonefile` creates an instant, zero-cost copy that shares physical
/// storage with the source until either copy is modified. This makes disk snapshots
/// near-instantaneous regardless of disk image size.
@_silgen_name("clonefile")
private func sys_clonefile(
    _ src: UnsafePointer<CChar>,
    _ dst: UnsafePointer<CChar>,
    _ flags: UInt32
) -> Int32

/// Flag for clonefile: do not follow symlinks.
private let CLONE_NOFOLLOW: UInt32 = 0x0001

/// Manages snapshot creation, restoration, and deletion for VM disk images.
///
/// Snapshots are stored within the VM bundle under:
/// ```
/// <uuid>.vortexvm/
///     snapshots/
///         <snapshot-uuid>/
///             metadata.json     -- SnapshotMetadata
///             disks/            -- COW clones of all disk images
/// ```
///
/// ## APFS Copy-on-Write
///
/// Disk image cloning uses `clonefile(2)` on APFS volumes for instant,
/// space-efficient copies. On non-APFS volumes, a byte-for-byte copy is
/// performed as a fallback.
///
/// ## Threading
///
/// All methods are synchronous. The class is `Sendable`.
public final class SnapshotRepository: Sendable {

    // MARK: - Constants

    private static let metadataFileName = "metadata.json"
    private static let disksSubdirectory = "disks"

    // MARK: - Properties

    private let fileManager: VMFileManager
    private let fm: FileManager

    // MARK: - Init

    /// Creates a snapshot repository backed by the given VM file manager.
    ///
    /// - Parameter fileManager: The `VMFileManager` controlling bundle locations.
    public init(fileManager: VMFileManager = VMFileManager()) {
        self.fileManager = fileManager
        self.fm = .default
    }

    // MARK: - Create snapshot

    /// Creates a new snapshot for a VM, cloning all disk images.
    ///
    /// 1. Creates a snapshot directory under `snapshots/<snapshot-id>/`.
    /// 2. Clones each disk image using `clonefile(2)` for APFS COW efficiency.
    /// 3. Writes `metadata.json` with the snapshot details.
    ///
    /// - Parameters:
    ///   - vmID: The VM's unique identifier.
    ///   - name: A user-provided name for the snapshot.
    ///   - description: An optional description.
    ///   - parentSnapshotID: The parent snapshot ID, if creating from another snapshot.
    /// - Returns: The created `SnapshotMetadata`.
    /// - Throws: `VortexError.vmNotFound` if the VM bundle does not exist.
    /// - Throws: `VortexError.snapshotFailed` on clonefile or I/O failure.
    @discardableResult
    public func createSnapshot(
        for vmID: UUID,
        name: String,
        description: String? = nil,
        parentSnapshotID: UUID? = nil
    ) throws -> SnapshotMetadata {
        guard fileManager.bundleExists(for: vmID) else {
            throw VortexError.vmNotFound(id: vmID)
        }
        try ensureSnapshotsSupported(for: vmID)

        let snapshotID = UUID()
        let snapshotDir = fileManager.snapshotPath(snapshotID: snapshotID, for: vmID)
        let disksDir = snapshotDir.appendingPathComponent(Self.disksSubdirectory, isDirectory: true)

        do {
            try fm.createDirectory(at: disksDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw VortexError.snapshotFailed(
                reason: "Failed to create snapshot directory at \(snapshotDir.path): \(error.localizedDescription)"
            )
        }

        // Clone each disk image in the VM's disks/ directory.
        let vmDisksDir = fileManager.subdirectoryPath(.disks, for: vmID)
        var totalSize: UInt64 = 0

        if fm.fileExists(atPath: vmDisksDir.path) {
            do {
                let diskFiles = try fm.contentsOfDirectory(
                    at: vmDisksDir,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                )

                for diskFile in diskFiles {
                    let destFile = disksDir.appendingPathComponent(diskFile.lastPathComponent)
                    try cloneFile(from: diskFile, to: destFile)

                    // Record logical size for metadata.
                    let resourceValues = try diskFile.resourceValues(forKeys: [.fileSizeKey])
                    totalSize += UInt64(resourceValues.fileSize ?? 0)
                }
            } catch let error as VortexError {
                // Clean up partial snapshot.
                try? fm.removeItem(at: snapshotDir)
                throw error
            } catch {
                try? fm.removeItem(at: snapshotDir)
                throw VortexError.snapshotFailed(
                    reason: "Failed to clone disk images for snapshot: \(error.localizedDescription)"
                )
            }
        }

        // Write metadata.
        let metadata = SnapshotMetadata(
            id: snapshotID,
            vmID: vmID,
            name: name,
            descriptionText: description,
            createdAt: Date(),
            vmStateAtCapture: .paused,
            sizeBytes: totalSize,
            parentSnapshotID: parentSnapshotID,
            storagePath: snapshotDir.path
        )

        do {
            try saveSnapshotMetadata(metadata, at: snapshotDir)
        } catch {
            try? fm.removeItem(at: snapshotDir)
            throw error
        }

        return metadata
    }

    // MARK: - Restore snapshot

    /// Restores a snapshot by replacing the VM's current disk images with
    /// the snapshot's cloned copies.
    ///
    /// The current disk images are removed and replaced with COW clones
    /// of the snapshot's disk images.
    ///
    /// - Parameters:
    ///   - snapshotID: The snapshot to restore.
    ///   - vmID: The VM to restore the snapshot into.
    /// - Throws: `VortexError.vmNotFound` if the VM bundle does not exist.
    /// - Throws: `VortexError.snapshotFailed` if the snapshot does not exist or
    ///   the restore operation fails.
    public func restoreSnapshot(_ snapshotID: UUID, for vmID: UUID) throws {
        guard fileManager.bundleExists(for: vmID) else {
            throw VortexError.vmNotFound(id: vmID)
        }
        try ensureSnapshotsSupported(for: vmID)

        let snapshotDir = fileManager.snapshotPath(snapshotID: snapshotID, for: vmID)
        let snapshotDisksDir = snapshotDir.appendingPathComponent(Self.disksSubdirectory, isDirectory: true)

        guard fm.fileExists(atPath: snapshotDir.path) else {
            throw VortexError.snapshotFailed(
                reason: "Snapshot \(snapshotID) not found for VM \(vmID)."
            )
        }

        guard fm.fileExists(atPath: snapshotDisksDir.path) else {
            throw VortexError.snapshotFailed(
                reason: "Snapshot \(snapshotID) has no disks directory."
            )
        }

        let vmDisksDir = fileManager.subdirectoryPath(.disks, for: vmID)

        do {
            // List snapshot disk files.
            let snapshotDiskFiles = try fm.contentsOfDirectory(
                at: snapshotDisksDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            // Remove current disk images and replace with clones from the snapshot.
            for snapshotDisk in snapshotDiskFiles {
                let targetDisk = vmDisksDir.appendingPathComponent(snapshotDisk.lastPathComponent)

                // Remove the existing disk image if present.
                if fm.fileExists(atPath: targetDisk.path) {
                    try fm.removeItem(at: targetDisk)
                }

                // Clone the snapshot's disk image into the VM's disks directory.
                try cloneFile(from: snapshotDisk, to: targetDisk)
            }
        } catch let error as VortexError {
            throw error
        } catch {
            throw VortexError.snapshotFailed(
                reason: "Failed to restore snapshot \(snapshotID): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Delete snapshot

    /// Deletes a snapshot's directory and all its contents.
    ///
    /// - Parameters:
    ///   - snapshotID: The snapshot to delete.
    ///   - vmID: The VM the snapshot belongs to.
    /// - Throws: `VortexError.snapshotFailed` if the snapshot does not exist or
    ///   deletion fails.
    public func deleteSnapshot(_ snapshotID: UUID, for vmID: UUID) throws {
        let snapshotDir = fileManager.snapshotPath(snapshotID: snapshotID, for: vmID)

        guard fm.fileExists(atPath: snapshotDir.path) else {
            throw VortexError.snapshotFailed(
                reason: "Snapshot \(snapshotID) not found for VM \(vmID)."
            )
        }

        do {
            try fm.removeItem(at: snapshotDir)
        } catch {
            throw VortexError.snapshotFailed(
                reason: "Failed to delete snapshot \(snapshotID): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - List snapshots

    /// Lists all snapshots for a VM, ordered by creation date descending.
    ///
    /// Snapshot directories whose `metadata.json` cannot be decoded are
    /// silently skipped.
    ///
    /// - Parameter vmID: The VM's unique identifier.
    /// - Returns: An array of `SnapshotMetadata`, newest first.
    /// - Throws: `VortexError.persistenceFailed` on failure to read the snapshots directory.
    public func listSnapshots(for vmID: UUID) throws -> [SnapshotMetadata] {
        let snapshotsDir = fileManager.snapshotsDirectory(for: vmID)

        guard fm.fileExists(atPath: snapshotsDir.path) else {
            return []
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: snapshotsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to list snapshots for VM \(vmID): \(error.localizedDescription)"
            )
        }

        var snapshots: [SnapshotMetadata] = []

        for dir in contents {
            let metadataFile = dir.appendingPathComponent(Self.metadataFileName)
            guard fm.fileExists(atPath: metadataFile.path) else { continue }

            do {
                let data = try Data(contentsOf: metadataFile)
                let metadata = try VMConfigCodec.decode(SnapshotMetadata.self, from: data)
                snapshots.append(metadata)
            } catch {
                // Skip corrupt snapshot metadata.
                fputs(
                    "warning: Skipping corrupt snapshot at \(dir.path): \(error.localizedDescription)\n",
                    stderr
                )
            }
        }

        // Sort by creation date, newest first.
        snapshots.sort { $0.createdAt > $1.createdAt }

        return snapshots
    }

    // MARK: - Metadata persistence

    /// Saves snapshot metadata to the snapshot's directory.
    ///
    /// - Parameter metadata: The metadata to persist.
    /// - Throws: `VortexError.persistenceFailed` on encoding or I/O failure.
    internal func saveSnapshotMetadata(_ metadata: SnapshotMetadata) throws {
        let snapshotDir = fileManager.snapshotPath(snapshotID: metadata.id, for: metadata.vmID)

        if !fm.fileExists(atPath: snapshotDir.path) {
            try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true, attributes: nil)
        }

        try saveSnapshotMetadata(metadata, at: snapshotDir)
    }

    /// Saves snapshot metadata to a specific directory.
    private func saveSnapshotMetadata(_ metadata: SnapshotMetadata, at directory: URL) throws {
        let metadataFile = directory.appendingPathComponent(Self.metadataFileName)
        do {
            let data = try VMConfigCodec.encode(metadata)
            try data.write(to: metadataFile, options: .atomic)
        } catch let error as VortexError {
            throw error
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to save snapshot metadata: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - External resource guard

    /// Snapshots are only well-defined for VMs whose mutable state lives inside
    /// the Vortex bundle. External-reference VMs keep their source of truth
    /// elsewhere and should not be snapshotted from inside Vortex.
    private func ensureSnapshotsSupported(for vmID: UUID) throws {
        let configPath = fileManager.configFilePath(for: vmID)

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw VortexError.vmNotFound(id: vmID)
        }

        let data = try Data(contentsOf: configPath)
        let config = try VMConfigCodec.decode(VMConfiguration.self, from: data)
        let bundlePath = fileManager.vmBundlePath(for: vmID)

        guard !config.usesExternalResources(bundlePath: bundlePath) else {
            throw VortexError.snapshotFailed(
                reason: "Snapshots are not supported for VMs that reference external files."
            )
        }
    }

    // MARK: - File cloning

    /// Clones a file using APFS `clonefile(2)`, falling back to a regular copy
    /// on non-APFS volumes.
    ///
    /// - Parameters:
    ///   - source: The source file URL.
    ///   - destination: The destination file URL (must not exist).
    /// - Throws: `VortexError.snapshotFailed` if both clonefile and copy fail.
    private func cloneFile(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { srcPath in
            destination.path.withCString { dstPath in
                sys_clonefile(srcPath, dstPath, CLONE_NOFOLLOW)
            }
        }

        if result == 0 {
            return // clonefile succeeded
        }

        // clonefile failed -- fall back to regular copy.
        // This handles non-APFS volumes or cross-volume snapshots.
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw VortexError.snapshotFailed(
                reason: "Failed to clone \(source.lastPathComponent): "
                    + "clonefile errno \(errno), copy error: \(error.localizedDescription)"
            )
        }
    }
}
