// TemplateRepository.swift — Pre-configured VM templates.
// VortexPersistence

import Foundation
import VortexCore

/// A pre-configured VM template providing sensible defaults for common
/// guest operating systems.
///
/// Templates are used to quickly create new VMs with appropriate hardware
/// profiles, disk sizes, and boot configurations for the target OS.
public struct VMTemplate: Sendable, Hashable, Identifiable {

    /// Stable identifier for this template.
    public let id: String

    /// Human-readable template name (e.g. "macOS Sequoia").
    public let name: String

    /// A brief description of what this template provides.
    public let description: String

    /// The guest operating system this template targets.
    public let guestOS: GuestOS

    /// The default hardware profile (CPU cores, memory).
    public let hardware: HardwareProfile

    /// Suggested boot disk size in GiB.
    public let suggestedDiskSizeGiB: UInt64

    /// The SF Symbol icon name for UI display.
    public let iconName: String

    public init(
        id: String,
        name: String,
        description: String,
        guestOS: GuestOS,
        hardware: HardwareProfile,
        suggestedDiskSizeGiB: UInt64,
        iconName: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.guestOS = guestOS
        self.hardware = hardware
        self.suggestedDiskSizeGiB = suggestedDiskSizeGiB
        self.iconName = iconName
    }
}

// MARK: - Built-in templates

extension VMTemplate {

    /// macOS Sequoia template with standard hardware profile.
    public static let macOSSequoia = VMTemplate(
        id: "macos-sequoia",
        name: "macOS Sequoia",
        description: "macOS 15 Sequoia on Apple Silicon. Includes clipboard sharing and VirtioFS shared folders.",
        guestOS: .macOS,
        hardware: HardwareProfile(cpuCoreCount: 4, memoryGiB: 8),
        suggestedDiskSizeGiB: 64,
        iconName: "desktopcomputer"
    )

    /// Ubuntu 24.04 ARM64 template with standard hardware profile.
    public static let ubuntu2404 = VMTemplate(
        id: "ubuntu-24.04-arm64",
        name: "Ubuntu 24.04 ARM64",
        description: "Ubuntu 24.04 LTS (Noble Numbat) for ARM64. UEFI boot with VirtIO devices and optional Rosetta translation.",
        guestOS: .linuxARM64,
        hardware: HardwareProfile(cpuCoreCount: 4, memoryGiB: 4),
        suggestedDiskSizeGiB: 32,
        iconName: "pc"
    )

    /// Windows 11 ARM template with performance hardware profile.
    public static let windows11ARM = VMTemplate(
        id: "windows-11-arm",
        name: "Windows 11 ARM",
        description: "Windows 11 on ARM. Requires a Windows ARM64 ISO and UEFI boot. Needs at least 4 GiB RAM and a 64 GiB disk.",
        guestOS: .windowsARM,
        hardware: HardwareProfile(cpuCoreCount: 4, memoryGiB: 8),
        suggestedDiskSizeGiB: 64,
        iconName: "pc"
    )
}

// MARK: - TemplateRepository

/// Provides access to built-in and user-defined VM templates.
///
/// Built-in templates cover macOS, Linux, and Windows guest OS types.
/// The repository is stateless and requires no initialization.
public struct TemplateRepository: Sendable {

    public init() {}

    // MARK: - Query

    /// Returns all available VM templates.
    ///
    /// - Returns: An array of all built-in templates, ordered by guest OS type
    ///   (macOS first, then Linux, then Windows).
    public func allTemplates() -> [VMTemplate] {
        [
            .macOSSequoia,
            .ubuntu2404,
            .windows11ARM,
        ]
    }

    /// Returns templates matching a specific guest OS.
    ///
    /// - Parameter guestOS: The guest OS to filter by.
    /// - Returns: Templates targeting the specified guest OS.
    public func templates(for guestOS: GuestOS) -> [VMTemplate] {
        allTemplates().filter { $0.guestOS == guestOS }
    }

    /// Finds a template by its identifier.
    ///
    /// - Parameter id: The template identifier (e.g. `"macos-sequoia"`).
    /// - Returns: The matching template, or `nil` if not found.
    public func template(withID id: String) -> VMTemplate? {
        allTemplates().first { $0.id == id }
    }

    // MARK: - VM creation from template

    /// Creates a new `VMConfiguration` from a template.
    ///
    /// The configuration is initialized with the template's hardware profile,
    /// guest OS, and boot configuration. Disk images are not created by this
    /// method -- the caller should use `VMFileManager.createDiskImage(at:sizeInBytes:)`
    /// afterward.
    ///
    /// - Parameters:
    ///   - template: The template to base the VM on.
    ///   - name: The display name for the new VM.
    ///   - fileManager: The file manager used to resolve bundle paths. Defaults
    ///     to a new instance using the standard Application Support path.
    /// - Returns: A `VMConfiguration` ready to be persisted via `VMRepository`.
    public func createVM(
        from template: VMTemplate,
        name: String,
        fileManager: VMFileManager = VMFileManager()
    ) -> VMConfiguration {
        let vmID = UUID()

        // Compute paths within the future bundle.
        let diskPath = fileManager.diskPath(vmID: vmID, diskName: "boot.img").path
        let diskSizeBytes = template.suggestedDiskSizeGiB * 1024 * 1024 * 1024

        let bootConfig: BootConfig
        let rosetta: RosettaConfig?
        let clipboard: ClipboardConfig

        switch template.guestOS {
        case .macOS:
            let auxPath = fileManager.subdirectoryPath(.auxiliary, for: vmID)
                .appendingPathComponent("auxiliary-storage").path
            let machineIDPath = fileManager.subdirectoryPath(.auxiliary, for: vmID)
                .appendingPathComponent("machine-identifier").path
            bootConfig = .macOS(
                auxiliaryStoragePath: auxPath,
                machineIdentifierPath: machineIDPath
            )
            rosetta = nil
            clipboard = .enabled

        case .linuxARM64:
            let efiPath = fileManager.subdirectoryPath(.efi, for: vmID)
                .appendingPathComponent("efi-variable-store").path
            bootConfig = .uefi(storePath: efiPath)
            rosetta = .disabled
            clipboard = .disabled

        case .windowsARM:
            let efiPath = fileManager.subdirectoryPath(.efi, for: vmID)
                .appendingPathComponent("efi-variable-store").path
            bootConfig = .uefi(storePath: efiPath)
            rosetta = nil
            clipboard = .disabled
        }

        return VMConfiguration(
            id: vmID,
            identity: VMIdentity(
                name: name,
                iconName: template.iconName
            ),
            guestOS: template.guestOS,
            hardware: template.hardware,
            storage: StorageConfiguration(disks: [
                .bootDisk(imagePath: diskPath, sizeGiB: template.suggestedDiskSizeGiB)
            ]),
            network: .singleNAT,
            display: .standard,
            audio: .systemDefaults,
            usb: .disabled,
            sharedFolders: [],
            clipboard: clipboard,
            rosetta: rosetta,
            bootConfig: bootConfig
        )
    }
}
