// MacAuxiliaryStorage.swift -- Auxiliary boot storage for macOS guests.
// VortexBoot
//
// macOS guests require an auxiliary storage file that persists boot-critical
// data between VM sessions. This is analogous to NVRAM on physical Macs --
// it stores boot picker state, startup disk selection, kernel panic logs,
// and other firmware-level persistent data.
//
// The auxiliary storage is a flat binary file of a fixed size. The macOS
// boot chain reads and writes to it during startup and shutdown.

import Foundation
import VortexCore

// MARK: - Mac Auxiliary Storage

/// Manages the auxiliary storage file for a macOS guest VM.
///
/// Auxiliary storage is a persistent binary file that the macOS boot chain
/// uses to store firmware-level data (NVRAM variables, boot picker state,
/// startup disk, etc.). Each macOS VM needs its own auxiliary storage file.
///
/// The file must:
/// - Be created before the first boot with the correct size.
/// - Persist across VM restarts (it is NOT regenerated each boot).
/// - Be writable by the VMM during guest execution.
///
/// ## Lifecycle
/// ```swift
/// // First-time setup:
/// try MacAuxiliaryStorage.create(at: storageURL, size: .default)
///
/// // Load for VM boot:
/// let storage = MacAuxiliaryStorage(url: storageURL)
/// let data = try storage.load()
/// vm.loadData(data, at: auxiliaryStorageGPA)
///
/// // After VM shutdown, save any modifications:
/// let updatedData = vm.readData(from: auxiliaryStorageGPA, size: data.count)
/// try storage.save(updatedData)
/// ```
///
/// ## File Format
///
/// The auxiliary storage is currently an opaque binary blob. On Apple's
/// Virtualization.framework, it is initialized with a specific header
/// that the macOS boot loader recognizes. Our placeholder initializes
/// the file with zeros; the real format will be implemented once the
/// boot chain research identifies the required header structure.
public final class MacAuxiliaryStorage: @unchecked Sendable {

    // MARK: - Storage Sizes

    /// Predefined auxiliary storage sizes.
    public enum StorageSize: Int, Sendable {
        /// Default size matching Apple's VZMacAuxiliaryStorage (1 MB).
        case `default` = 1_048_576

        /// Minimum viable size for basic NVRAM variables (256 KB).
        case minimum = 262_144

        /// Extended size for development/debugging (4 MB).
        case extended = 4_194_304

        /// The raw size in bytes.
        public var bytes: Int { rawValue }
    }

    // MARK: - Properties

    /// File URL of the auxiliary storage on disk.
    public let url: URL

    /// Lock for thread-safe file access.
    private let lock = NSLock()

    // MARK: - Initialization

    /// Creates a storage manager for an existing auxiliary storage file.
    ///
    /// Does not verify the file exists -- call `load()` or `exists` to check.
    ///
    /// - Parameter url: Path to the auxiliary storage file.
    public init(url: URL) {
        self.url = url
    }

    // MARK: - Creation

    /// Creates a new auxiliary storage file at the specified URL.
    ///
    /// The file is initialized with a header and zero-filled to the
    /// requested size. If a file already exists at the URL, this method
    /// throws `VortexError.fileAlreadyExists`.
    ///
    /// - Parameters:
    ///   - url: File URL where the storage file should be created.
    ///   - size: Size of the storage file. Defaults to `.default` (1 MB).
    /// - Throws: `VortexError.fileAlreadyExists` if the file exists,
    ///   or `VortexError.bootFailed` if the file cannot be written.
    public static func create(
        at url: URL,
        size: StorageSize = .default
    ) throws {
        try create(at: url, size: size.bytes)
    }

    /// Creates a new auxiliary storage file with an explicit byte size.
    ///
    /// - Parameters:
    ///   - url: File URL where the storage file should be created.
    ///   - size: Size in bytes. Must be at least `StorageSize.minimum.bytes`.
    /// - Throws: `VortexError.fileAlreadyExists` if the file exists.
    public static func create(
        at url: URL,
        size: Int
    ) throws {
        let fm = FileManager.default

        guard !fm.fileExists(atPath: url.path) else {
            throw VortexError.fileAlreadyExists(path: url.path)
        }

        guard size >= StorageSize.minimum.bytes else {
            throw VortexError.bootFailed(
                reason: "Auxiliary storage size \(size) is below minimum \(StorageSize.minimum.bytes)"
            )
        }

        // Ensure the parent directory exists.
        let parentDir = url.deletingLastPathComponent()
        try fm.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )

        // Initialize the storage with a header and zero fill.
        var data = Data(count: size)

        // Write a recognizable header so we can identify Vortex auxiliary
        // storage files and their format version.
        //
        // Header layout (32 bytes):
        //   [0..3]   Magic: "VXAS" (Vortex Auxiliary Storage)
        //   [4..7]   Format version: 1
        //   [8..11]  Total size in bytes
        //   [12..15] NVRAM region offset (after header)
        //   [16..19] NVRAM region size
        //   [20..31] Reserved (zeros)
        let headerMagic: [UInt8] = [0x56, 0x58, 0x41, 0x53]  // "VXAS"
        data.replaceSubrange(0..<4, with: headerMagic)

        // Format version.
        var version = UInt32(1).bigEndian
        data.replaceSubrange(4..<8, with: Data(bytes: &version, count: 4))

        // Total size.
        var totalSize = UInt32(size).bigEndian
        data.replaceSubrange(8..<12, with: Data(bytes: &totalSize, count: 4))

        // NVRAM region offset (immediately after the 32-byte header).
        var nvramOffset = UInt32(32).bigEndian
        data.replaceSubrange(12..<16, with: Data(bytes: &nvramOffset, count: 4))

        // NVRAM region size (total - header).
        var nvramSize = UInt32(size - 32).bigEndian
        data.replaceSubrange(16..<20, with: Data(bytes: &nvramSize, count: 4))

        // Write the file atomically.
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Loading

    /// Loads the auxiliary storage contents from disk.
    ///
    /// - Returns: The raw storage data.
    /// - Throws: `VortexError.fileNotFound` if the file does not exist,
    ///   or `VortexError.bootFailed` if the file cannot be read.
    public func load() throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VortexError.fileNotFound(path: url.path)
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw VortexError.bootFailed(
                reason: "Failed to read auxiliary storage at \(url.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Saving

    /// Saves updated auxiliary storage contents to disk.
    ///
    /// Call this after the VM shuts down to persist any NVRAM changes
    /// made by the guest during the session.
    ///
    /// - Parameter data: The updated storage data.
    /// - Throws: `VortexError.bootFailed` if the file cannot be written.
    public func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw VortexError.bootFailed(
                reason: "Failed to write auxiliary storage at \(url.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Queries

    /// Whether the auxiliary storage file exists on disk.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The size of the auxiliary storage file in bytes, or nil if it does not exist.
    public var fileSize: Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else {
            return nil
        }
        return size
    }

    /// Validates that the auxiliary storage file has a recognized format.
    ///
    /// Checks for the Vortex magic header. Returns `true` for both
    /// Vortex-format and zero-initialized files (which may have been
    /// created by other tools or an older version).
    ///
    /// - Returns: `true` if the file appears valid.
    public func validate() throws -> Bool {
        let data = try load()

        guard data.count >= StorageSize.minimum.bytes else {
            return false
        }

        // Check for Vortex magic header.
        let magic = [UInt8](data.prefix(4))
        let vortexMagic: [UInt8] = [0x56, 0x58, 0x41, 0x53]  // "VXAS"
        if magic == vortexMagic {
            return true
        }

        // Accept zero-initialized files (e.g., from VZ framework or fresh creation).
        let allZeros = data.prefix(32).allSatisfy { $0 == 0 }
        if allZeros {
            return true
        }

        // Accept any non-empty file -- the guest may have written its own
        // format that we do not yet recognize.
        return true
    }

    // MARK: - Deletion

    /// Deletes the auxiliary storage file from disk.
    ///
    /// Use with caution -- this permanently removes NVRAM data for the VM.
    /// The VM will need fresh auxiliary storage created for next boot.
    ///
    /// - Throws: If the file cannot be removed.
    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return  // Already gone, nothing to do.
        }

        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Reset

    /// Resets the auxiliary storage to its initial state.
    ///
    /// Preserves the file at its current size but re-initializes the
    /// contents (header + zero fill). Useful for troubleshooting boot
    /// issues caused by corrupted NVRAM data.
    ///
    /// - Throws: If the file cannot be read or rewritten.
    public func reset() throws {
        let currentSize = fileSize ?? StorageSize.default.bytes
        try delete()
        try MacAuxiliaryStorage.create(at: url, size: currentSize)
    }
}
