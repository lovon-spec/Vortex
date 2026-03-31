// StorageConfig.swift — Disk and storage configuration.
// VortexCore

import Foundation

/// Top-level storage configuration for a VM, containing one or more disk devices.
public struct StorageConfiguration: Codable, Sendable, Hashable {
    /// Ordered list of disk configurations. The first disk is typically the boot disk.
    public var disks: [DiskConfig]

    public init(disks: [DiskConfig] = []) {
        self.disks = disks
    }

    /// The primary (boot) disk, if any.
    public var bootDisk: DiskConfig? {
        disks.first
    }

    /// Total allocated storage across all disks, in bytes.
    public var totalAllocatedBytes: UInt64 {
        disks.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// Configuration for a single virtual disk device.
public struct DiskConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID

    /// Human-readable label for this disk (e.g. "Boot Disk", "Data Volume").
    public var label: String

    /// Absolute path to the disk image file on the host.
    public var imagePath: String

    /// Disk size in bytes.
    public var sizeBytes: UInt64

    /// The virtual device type exposed to the guest.
    public var deviceType: DiskDeviceType

    /// Host-side caching mode for I/O operations.
    public var cachingMode: DiskCachingMode

    /// Synchronization mode controlling durability guarantees.
    public var syncMode: DiskSyncMode

    /// Whether the disk is presented as read-only to the guest.
    public var readOnly: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        imagePath: String,
        sizeBytes: UInt64,
        deviceType: DiskDeviceType = .virtioBlock,
        cachingMode: DiskCachingMode = .automatic,
        syncMode: DiskSyncMode = .full,
        readOnly: Bool = false
    ) {
        self.id = id
        self.label = label
        self.imagePath = imagePath
        self.sizeBytes = sizeBytes
        self.deviceType = deviceType
        self.cachingMode = cachingMode
        self.syncMode = syncMode
        self.readOnly = readOnly
    }

    // MARK: - Convenience

    /// Disk size in GiB as a floating-point value.
    public var sizeGiB: Double {
        Double(sizeBytes) / (1024.0 * 1024.0 * 1024.0)
    }

    /// Formatted display string (e.g. "64 GiB").
    public var sizeDisplayString: String {
        let gib = sizeGiB
        if gib == gib.rounded() {
            return "\(Int(gib)) GiB"
        }
        return String(format: "%.1f GiB", gib)
    }

    // MARK: - Factory

    /// Create a boot disk configuration with sensible defaults.
    /// - Parameters:
    ///   - imagePath: Path to the disk image on the host.
    ///   - sizeGiB: Disk size in gibibytes.
    public static func bootDisk(imagePath: String, sizeGiB: UInt64) -> DiskConfig {
        DiskConfig(
            label: "Boot Disk",
            imagePath: imagePath,
            sizeBytes: sizeGiB * 1024 * 1024 * 1024,
            deviceType: .virtioBlock,
            cachingMode: .automatic,
            syncMode: .full
        )
    }

    /// Create a secondary data disk configuration.
    public static func dataDisk(imagePath: String, sizeGiB: UInt64, label: String = "Data") -> DiskConfig {
        DiskConfig(
            label: label,
            imagePath: imagePath,
            sizeBytes: sizeGiB * 1024 * 1024 * 1024,
            deviceType: .virtioBlock,
            cachingMode: .automatic,
            syncMode: .full
        )
    }
}

// MARK: - Device type

/// The virtual block device type exposed to the guest.
public enum DiskDeviceType: String, Codable, Sendable, CaseIterable {
    /// VirtIO block device -- highest performance on supported guests.
    case virtioBlock

    /// USB mass storage -- broadest compatibility.
    case usbMassStorage
}

// MARK: - Caching mode

/// Controls how disk I/O is cached on the host side.
public enum DiskCachingMode: String, Codable, Sendable, CaseIterable {
    /// Let the hypervisor decide based on the device type and host conditions.
    case automatic

    /// Write-back caching (faster, data may be lost on host crash).
    case writeBack

    /// Write-through caching (slower, data is durable on each write).
    case writeThrough

    /// No caching -- direct I/O to the image file.
    case none
}

// MARK: - Sync mode

/// Controls how aggressively the host flushes writes to the underlying storage.
public enum DiskSyncMode: String, Codable, Sendable, CaseIterable {
    /// Full sync: guest flush requests are honored and propagated to host storage.
    case full

    /// Unsafe: guest flush requests may be coalesced or dropped for speed.
    /// Only appropriate for ephemeral/scratch disks.
    case unsafe
}
