// VMFileManager.swift — On-disk VM bundle directory management.
// VortexPersistence

import Foundation
import VortexCore

/// Manages the on-disk directory structure for Vortex VM bundles.
///
/// Each VM is stored as a directory bundle at:
/// ```
/// ~/Library/Application Support/Vortex/VirtualMachines/<uuid>.vortexvm/
/// ```
///
/// Bundle contents:
/// ```
/// <uuid>.vortexvm/
///     config.json           -- VMConfiguration
///     platform.json         -- Platform-specific metadata (machine ID, etc.)
///     disks/                -- Disk image files
///     efi/                  -- EFI variable store, firmware images
///     auxiliary/            -- macOS auxiliary storage (NVRAM), machine identifiers
///     boot/                 -- Kernel, initrd, IPSW references
///     snapshots/            -- Snapshot disk clones and metadata
///     logs/                 -- VM runtime logs
/// ```
///
/// - Note: All public methods are synchronous and perform file I/O on the caller's
///   thread. Callers should dispatch to a background queue if needed.
public final class VMFileManager: Sendable {

    // MARK: - Constants

    /// The file extension used for VM bundle directories.
    public static let bundleExtension = "vortexvm"

    /// Standard file name for the VM configuration JSON.
    public static let configFileName = "config.json"

    /// Standard file name for platform-specific metadata JSON.
    public static let platformFileName = "platform.json"

    /// Subdirectory names within a VM bundle.
    public enum Subdirectory: String, CaseIterable, Sendable {
        case disks
        case efi
        case auxiliary
        case boot
        case snapshots
        case logs
    }

    // MARK: - Properties

    /// Root directory containing all VM bundles.
    ///
    /// Defaults to `~/Library/Application Support/Vortex/VirtualMachines/`.
    public let baseDirectory: URL

    private let fileManager: FileManager

    // MARK: - Init

    /// Creates a `VMFileManager` with a custom base directory.
    ///
    /// - Parameter baseDirectory: The root directory for VM bundles. Created on
    ///   first use if it does not exist.
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.fileManager = .default
    }

    /// Creates a `VMFileManager` using the default Application Support location.
    ///
    /// The base directory is:
    /// `~/Library/Application Support/Vortex/VirtualMachines/`
    public convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let base = appSupport
            .appendingPathComponent("Vortex", isDirectory: true)
            .appendingPathComponent("VirtualMachines", isDirectory: true)
        self.init(baseDirectory: base)
    }

    // MARK: - Bundle paths

    /// Returns the bundle directory URL for a given VM ID.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Returns: The URL to `<baseDirectory>/<id>.vortexvm/`.
    public func vmBundlePath(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent(
            "\(id.uuidString).\(Self.bundleExtension)",
            isDirectory: true
        )
    }

    /// Returns the path to the `config.json` file within a VM bundle.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Returns: URL to the configuration file.
    public func configFilePath(for id: UUID) -> URL {
        vmBundlePath(for: id).appendingPathComponent(Self.configFileName)
    }

    /// Returns the path to the `platform.json` file within a VM bundle.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Returns: URL to the platform metadata file.
    public func platformFilePath(for id: UUID) -> URL {
        vmBundlePath(for: id).appendingPathComponent(Self.platformFileName)
    }

    /// Returns the path to a subdirectory within a VM bundle.
    ///
    /// - Parameters:
    ///   - subdirectory: The subdirectory to locate.
    ///   - id: The VM's unique identifier.
    /// - Returns: URL to the subdirectory.
    public func subdirectoryPath(_ subdirectory: Subdirectory, for id: UUID) -> URL {
        vmBundlePath(for: id).appendingPathComponent(subdirectory.rawValue, isDirectory: true)
    }

    /// Returns the path to a disk image file within a VM bundle.
    ///
    /// - Parameters:
    ///   - vmID: The VM's unique identifier.
    ///   - diskName: The disk image file name (e.g. `"boot.img"`, `"data.raw"`).
    /// - Returns: URL to the disk image file.
    public func diskPath(vmID: UUID, diskName: String) -> URL {
        subdirectoryPath(.disks, for: vmID).appendingPathComponent(diskName)
    }

    /// Returns the path to the snapshots directory for a specific VM.
    ///
    /// - Parameter vmID: The VM's unique identifier.
    /// - Returns: URL to the snapshots directory.
    public func snapshotsDirectory(for vmID: UUID) -> URL {
        subdirectoryPath(.snapshots, for: vmID)
    }

    /// Returns the path to a specific snapshot's directory within a VM bundle.
    ///
    /// - Parameters:
    ///   - snapshotID: The snapshot's unique identifier.
    ///   - vmID: The VM's unique identifier.
    /// - Returns: URL to the snapshot directory.
    public func snapshotPath(snapshotID: UUID, for vmID: UUID) -> URL {
        snapshotsDirectory(for: vmID)
            .appendingPathComponent(snapshotID.uuidString, isDirectory: true)
    }

    // MARK: - Bundle lifecycle

    /// Creates the complete directory structure for a new VM bundle.
    ///
    /// This creates the bundle directory and all standard subdirectories
    /// (`disks/`, `efi/`, `auxiliary/`, `boot/`, `snapshots/`, `logs/`).
    /// The `config.json` file is written with the provided configuration.
    ///
    /// - Parameter config: The VM configuration to persist in the bundle.
    /// - Returns: The URL of the created bundle directory.
    /// - Throws: `VortexError.fileAlreadyExists` if a bundle with this ID already exists.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    @discardableResult
    public func createVMBundle(for config: VMConfiguration) throws -> URL {
        let bundlePath = vmBundlePath(for: config.id)

        // Guard against overwriting an existing bundle.
        if fileManager.fileExists(atPath: bundlePath.path) {
            throw VortexError.fileAlreadyExists(path: bundlePath.path)
        }

        do {
            // Create the bundle directory.
            try fileManager.createDirectory(
                at: bundlePath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Create all subdirectories.
            for subdirectory in Subdirectory.allCases {
                let subPath = subdirectoryPath(subdirectory, for: config.id)
                try fileManager.createDirectory(
                    at: subPath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }

            // Write the config.json.
            let configData = try VMConfigCodec.encode(config)
            try configData.write(to: configFilePath(for: config.id), options: .atomic)

        } catch let error as VortexError {
            // Re-throw VortexErrors as-is.
            throw error
        } catch {
            // Clean up partial bundle on failure.
            try? fileManager.removeItem(at: bundlePath)
            throw VortexError.persistenceFailed(
                reason: "Failed to create VM bundle at \(bundlePath.path): \(error.localizedDescription)"
            )
        }

        return bundlePath
    }

    /// Deletes the entire VM bundle directory for the given VM ID.
    ///
    /// This permanently removes all files in the bundle: configuration,
    /// disk images, snapshots, logs, and auxiliary data.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Throws: `VortexError.vmNotFound` if no bundle exists for this ID.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    public func deleteVMBundle(id: UUID) throws {
        let bundlePath = vmBundlePath(for: id)

        guard fileManager.fileExists(atPath: bundlePath.path) else {
            throw VortexError.vmNotFound(id: id)
        }

        do {
            try fileManager.removeItem(at: bundlePath)
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to delete VM bundle at \(bundlePath.path): \(error.localizedDescription)"
            )
        }
    }

    /// Lists all VM bundle directories in the base directory.
    ///
    /// - Returns: An array of URLs pointing to `*.vortexvm` directories, sorted
    ///   alphabetically by bundle name.
    /// - Throws: `VortexError.persistenceFailed` on I/O failure.
    public func listVMBundles() throws -> [URL] {
        // Ensure base directory exists; return empty list if it doesn't.
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            return contents
                .filter { $0.pathExtension == Self.bundleExtension }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to list VM bundles at \(baseDirectory.path): \(error.localizedDescription)"
            )
        }
    }

    /// Checks whether a VM bundle directory exists for the given ID.
    ///
    /// - Parameter id: The VM's unique identifier.
    /// - Returns: `true` if the bundle directory exists.
    public func bundleExists(for id: UUID) -> Bool {
        fileManager.fileExists(atPath: vmBundlePath(for: id).path)
    }

    // MARK: - Disk image creation

    /// Creates a sparse RAW disk image file at the given URL.
    ///
    /// Uses `ftruncate(2)` to set the file size without allocating physical
    /// storage, relying on APFS sparse file support for efficient storage.
    ///
    /// - Parameters:
    ///   - url: The file URL where the disk image should be created.
    ///   - sizeInBytes: The logical size of the disk image in bytes.
    /// - Throws: `VortexError.fileAlreadyExists` if a file already exists at the URL.
    /// - Throws: `VortexError.diskOperationFailed` on I/O failure.
    public func createDiskImage(at url: URL, sizeInBytes: UInt64) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw VortexError.fileAlreadyExists(path: url.path)
        }

        // Ensure the parent directory exists.
        let parentDir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            do {
                try fileManager.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw VortexError.diskOperationFailed(
                    reason: "Failed to create parent directory \(parentDir.path): \(error.localizedDescription)"
                )
            }
        }

        // Create the file and set its size via ftruncate for sparse allocation.
        guard fileManager.createFile(atPath: url.path, contents: nil, attributes: nil) else {
            throw VortexError.diskOperationFailed(
                reason: "Failed to create disk image file at \(url.path)."
            )
        }

        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else {
            throw VortexError.diskOperationFailed(
                reason: "Failed to open disk image for writing at \(url.path): errno \(errno)."
            )
        }
        defer { close(fd) }

        let result = ftruncate(fd, off_t(sizeInBytes))
        guard result == 0 else {
            // Clean up the empty file on failure.
            try? fileManager.removeItem(at: url)
            throw VortexError.diskOperationFailed(
                reason: "ftruncate failed for \(url.path): errno \(errno)."
            )
        }
    }

    // MARK: - Ensure base directory

    /// Ensures the base directory exists, creating it if necessary.
    ///
    /// - Throws: `VortexError.persistenceFailed` if the directory cannot be created.
    public func ensureBaseDirectoryExists() throws {
        guard !fileManager.fileExists(atPath: baseDirectory.path) else { return }
        do {
            try fileManager.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw VortexError.persistenceFailed(
                reason: "Failed to create base directory at \(baseDirectory.path): \(error.localizedDescription)"
            )
        }
    }
}
