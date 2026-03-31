// VMConfiguration.swift — Central VM configuration model.
// VortexCore

import Foundation

/// The complete, persistable configuration for a virtual machine.
///
/// `VMConfiguration` is the single source of truth for everything needed to
/// create and start a VM: hardware resources, storage layout, network topology,
/// display settings, audio routing, USB passthrough, shared folders, and boot
/// parameters. It is fully `Codable` for JSON serialization and `Sendable`
/// for safe use across concurrency domains.
public struct VMConfiguration: Codable, Identifiable, Sendable, Hashable {
    /// Unique identifier for this VM configuration.
    public let id: UUID

    /// Human-facing identity (name, icon, notes, tags).
    public var identity: VMIdentity

    /// The guest operating system type.
    public var guestOS: GuestOS

    /// CPU and memory allocation.
    public var hardware: HardwareProfile

    /// Disk configuration.
    public var storage: StorageConfiguration

    /// Network interfaces.
    public var network: NetworkConfiguration

    /// Virtual display settings.
    public var display: DisplayConfiguration

    /// Per-VM audio device routing.
    public var audio: AudioConfig

    /// USB device passthrough.
    public var usb: USBConfig

    /// VirtioFS shared folder mounts.
    public var sharedFolders: [SharedFolderConfig]

    /// Clipboard sharing between host and guest.
    public var clipboard: ClipboardConfig

    /// Rosetta 2 translation (Linux ARM64 guests only).
    public var rosetta: RosettaConfig?

    /// Boot and firmware settings.
    public var bootConfig: BootConfig

    /// When this configuration was first created.
    public var createdAt: Date

    /// When this configuration was last modified.
    public var modifiedAt: Date

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        identity: VMIdentity,
        guestOS: GuestOS,
        hardware: HardwareProfile = .standard,
        storage: StorageConfiguration = StorageConfiguration(),
        network: NetworkConfiguration = .singleNAT,
        display: DisplayConfiguration = .standard,
        audio: AudioConfig = .systemDefaults,
        usb: USBConfig = .disabled,
        sharedFolders: [SharedFolderConfig] = [],
        clipboard: ClipboardConfig = .enabled,
        rosetta: RosettaConfig? = nil,
        bootConfig: BootConfig,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.identity = identity
        self.guestOS = guestOS
        self.hardware = hardware
        self.storage = storage
        self.network = network
        self.display = display
        self.audio = audio
        self.usb = usb
        self.sharedFolders = sharedFolders
        self.clipboard = clipboard
        self.rosetta = rosetta
        self.bootConfig = bootConfig
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    // MARK: - Mutation helper

    /// Returns a copy of this configuration with `modifiedAt` set to now.
    /// Use this when persisting changes so the timestamp stays accurate.
    public func touchingModifiedDate() -> VMConfiguration {
        var copy = self
        copy.modifiedAt = Date()
        return copy
    }

    // MARK: - Validation

    /// Validates the entire configuration and returns all issues found.
    public func validate() -> [String] {
        var issues: [String] = []

        // Identity
        if identity.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("VM name must not be empty.")
        }

        // Hardware
        for issue in hardware.validate() {
            issues.append(issue.description)
        }

        // Storage
        if storage.disks.isEmpty {
            issues.append("At least one disk must be configured.")
        }
        for disk in storage.disks {
            if disk.imagePath.isEmpty {
                issues.append("Disk \"\(disk.label)\" has an empty image path.")
            }
            if disk.sizeBytes == 0 {
                issues.append("Disk \"\(disk.label)\" has zero size.")
            }
        }

        // Boot config consistency
        switch bootConfig.mode {
        case .macOS:
            if guestOS != .macOS {
                issues.append("macOS boot mode requires macOS guest OS type.")
            }
        case .uefi:
            if guestOS == .macOS {
                issues.append("macOS guests should use macOS boot mode, not UEFI.")
            }
        case .linuxKernel:
            if bootConfig.kernelPath == nil || bootConfig.kernelPath?.isEmpty == true {
                issues.append("Direct Linux kernel boot requires a kernel path.")
            }
        }

        // Rosetta
        if let rosetta = rosetta, rosetta.enabled, !guestOS.supportsRosetta {
            issues.append("Rosetta is only supported on Linux ARM64 guests.")
        }

        // Clipboard
        if clipboard.enabled && !guestOS.supportsClipboardSharing {
            issues.append("Clipboard sharing is only supported on macOS guests.")
        }

        return issues
    }

    /// Whether the configuration passes all validation checks.
    public var isValid: Bool {
        validate().isEmpty
    }

    // MARK: - Factory methods

    /// Create a default macOS VM configuration.
    /// - Parameters:
    ///   - name: Display name for the VM.
    ///   - diskImagePath: Path for the boot disk image.
    ///   - diskSizeGiB: Boot disk size in GiB.
    ///   - auxiliaryStoragePath: Path to the NVRAM file.
    ///   - machineIdentifierPath: Path to the machine identifier file.
    public static func defaultMacOS(
        name: String,
        diskImagePath: String,
        diskSizeGiB: UInt64 = 64,
        auxiliaryStoragePath: String,
        machineIdentifierPath: String
    ) -> VMConfiguration {
        VMConfiguration(
            identity: VMIdentity(name: name, iconName: "desktopcomputer"),
            guestOS: .macOS,
            hardware: .standard,
            storage: StorageConfiguration(disks: [
                .bootDisk(imagePath: diskImagePath, sizeGiB: diskSizeGiB)
            ]),
            network: .singleNAT,
            display: .standard,
            audio: .systemDefaults,
            clipboard: .enabled,
            bootConfig: .macOS(
                auxiliaryStoragePath: auxiliaryStoragePath,
                machineIdentifierPath: machineIdentifierPath
            )
        )
    }

    /// Create a default Linux VM configuration.
    /// - Parameters:
    ///   - name: Display name for the VM.
    ///   - diskImagePath: Path for the boot disk image.
    ///   - diskSizeGiB: Boot disk size in GiB.
    ///   - efiStorePath: Path to the EFI variable store.
    public static func defaultLinux(
        name: String,
        diskImagePath: String,
        diskSizeGiB: UInt64 = 64,
        efiStorePath: String
    ) -> VMConfiguration {
        VMConfiguration(
            identity: VMIdentity(name: name, iconName: "pc"),
            guestOS: .linuxARM64,
            hardware: .standard,
            storage: StorageConfiguration(disks: [
                .bootDisk(imagePath: diskImagePath, sizeGiB: diskSizeGiB)
            ]),
            network: .singleNAT,
            display: .standard,
            audio: .systemDefaults,
            clipboard: .disabled,
            rosetta: .disabled,
            bootConfig: .uefi(storePath: efiStorePath)
        )
    }
}
