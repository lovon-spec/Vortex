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

    /// The VM execution backend.
    public var backend: VMBackend

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
        backend: VMBackend = .appleVirtualization,
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
        self.backend = backend
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

        // Network
        for (index, iface) in network.interfaces.enumerated() {
            let name = iface.label ?? "Network interface \(index + 1)"
            switch iface.mode {
            case .bridged(let hostInterface):
                if hostInterface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("\(name) has an empty bridged host interface.")
                }
            case .vmnetShared(let vmnet):
                if vmnet.networkID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("\(name) has an empty shared LAN network ID.")
                }
            case .nat, .hostOnly:
                break
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

        // Backend support
        switch backend {
        case .appleVirtualization:
            break
        case .vortexHV:
            if guestOS != .linuxARM64 {
                issues.append("VortexHV backend currently supports Linux ARM64 guests.")
            }
            if bootConfig.mode == .macOS {
                issues.append("VortexHV backend cannot use macOS boot mode.")
            }
            if audio.enabled && bootConfig.mode != .uefi {
                issues.append("VortexHV audio currently requires UEFI boot with PCI virtio devices.")
            }
            if usb.enabled {
                issues.append("VortexHV backend does not support USB passthrough yet.")
            }
            if !sharedFolders.isEmpty {
                issues.append("VortexHV backend does not support shared folders yet.")
            }
            if rosetta?.enabled == true {
                issues.append("VortexHV backend does not support Rosetta yet.")
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

    // MARK: - Codable compatibility

    enum CodingKeys: String, CodingKey {
        case id
        case identity
        case guestOS
        case backend
        case hardware
        case storage
        case network
        case display
        case audio
        case usb
        case sharedFolders
        case clipboard
        case rosetta
        case bootConfig
        case createdAt
        case modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.identity = try container.decode(VMIdentity.self, forKey: .identity)
        self.guestOS = try container.decode(GuestOS.self, forKey: .guestOS)
        self.backend = try container.decodeIfPresent(VMBackend.self, forKey: .backend) ?? .appleVirtualization
        self.hardware = try container.decode(HardwareProfile.self, forKey: .hardware)
        self.storage = try container.decode(StorageConfiguration.self, forKey: .storage)
        self.network = try container.decode(NetworkConfiguration.self, forKey: .network)
        self.display = try container.decode(DisplayConfiguration.self, forKey: .display)
        self.audio = try container.decode(AudioConfig.self, forKey: .audio)
        self.usb = try container.decodeIfPresent(USBConfig.self, forKey: .usb) ?? .disabled
        self.sharedFolders = try container.decodeIfPresent([SharedFolderConfig].self, forKey: .sharedFolders) ?? []
        self.clipboard = try container.decode(ClipboardConfig.self, forKey: .clipboard)
        self.rosetta = try container.decodeIfPresent(RosettaConfig.self, forKey: .rosetta)
        self.bootConfig = try container.decode(BootConfig.self, forKey: .bootConfig)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(identity, forKey: .identity)
        try container.encode(guestOS, forKey: .guestOS)
        try container.encode(backend, forKey: .backend)
        try container.encode(hardware, forKey: .hardware)
        try container.encode(storage, forKey: .storage)
        try container.encode(network, forKey: .network)
        try container.encode(display, forKey: .display)
        try container.encode(audio, forKey: .audio)
        try container.encode(usb, forKey: .usb)
        try container.encode(sharedFolders, forKey: .sharedFolders)
        try container.encodeIfPresent(rosetta, forKey: .rosetta)
        try container.encode(clipboard, forKey: .clipboard)
        try container.encode(bootConfig, forKey: .bootConfig)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }

    // MARK: - Path introspection

    /// Returns every host-side file path referenced by this configuration.
    ///
    /// This is used to detect VMs that point at external files instead of
    /// storing all mutable state inside their own `.vortexvm` bundle.
    public var referencedFilePaths: [String] {
        var paths = storage.disks.map(\.imagePath)

        let bootPaths = [
            bootConfig.uefiStorePath,
            bootConfig.uefiFirmwarePath,
            bootConfig.kernelPath,
            bootConfig.initrdPath,
            bootConfig.macOSRestoreImagePath,
            bootConfig.auxiliaryStoragePath,
            bootConfig.machineIdentifierPath,
            bootConfig.hardwareModelPath,
        ]

        paths.append(contentsOf: bootPaths.compactMap { $0 })
        return paths
    }

    /// Returns true when any referenced file path lives outside the VM bundle.
    public func usesExternalResources(bundlePath: URL) -> Bool {
        let bundleRoot = bundlePath.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let bundlePrefix = bundleRoot.hasSuffix("/") ? bundleRoot : bundleRoot + "/"

        return referencedFilePaths.contains { path in
            let normalized = URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return normalized != bundleRoot && !normalized.hasPrefix(bundlePrefix)
        }
    }

    // MARK: - Factory methods

    /// Create a default macOS VM configuration.
    /// - Parameters:
    ///   - name: Display name for the VM.
    ///   - diskImagePath: Path for the boot disk image.
    ///   - diskSizeGiB: Boot disk size in GiB.
    ///   - auxiliaryStoragePath: Path to the NVRAM file.
    ///   - machineIdentifierPath: Path to the machine identifier file.
    ///   - hardwareModelPath: Optional explicit path to the hardware model file.
    public static func defaultMacOS(
        name: String,
        diskImagePath: String,
        diskSizeGiB: UInt64 = 64,
        auxiliaryStoragePath: String,
        machineIdentifierPath: String,
        hardwareModelPath: String? = nil
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
                machineIdentifierPath: machineIdentifierPath,
                hardwareModelPath: hardwareModelPath
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
