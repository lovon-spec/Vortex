// BootConfig.swift — Boot and firmware configuration.
// VortexCore

import Foundation

/// Boot configuration controlling how the VM boots its guest operating system.
public struct BootConfig: Codable, Sendable, Hashable {
    /// The boot mechanism to use.
    public var mode: BootMode

    /// Path to the UEFI firmware image (required for UEFI mode).
    public var uefiStorePath: String?

    /// Path to the kernel image (used for direct Linux kernel boot).
    public var kernelPath: String?

    /// Kernel command-line arguments (used for direct Linux kernel boot).
    public var kernelCommandLine: String?

    /// Path to the initial ramdisk (used for direct Linux kernel boot).
    public var initrdPath: String?

    /// Path to the macOS IPSW restore image (used for macOS initial install).
    public var macOSRestoreImagePath: String?

    /// Path to the auxiliary storage (NVRAM) for macOS guests.
    public var auxiliaryStoragePath: String?

    /// Path to the machine identifier file for macOS guests.
    public var machineIdentifierPath: String?

    public init(
        mode: BootMode,
        uefiStorePath: String? = nil,
        kernelPath: String? = nil,
        kernelCommandLine: String? = nil,
        initrdPath: String? = nil,
        macOSRestoreImagePath: String? = nil,
        auxiliaryStoragePath: String? = nil,
        machineIdentifierPath: String? = nil
    ) {
        self.mode = mode
        self.uefiStorePath = uefiStorePath
        self.kernelPath = kernelPath
        self.kernelCommandLine = kernelCommandLine
        self.initrdPath = initrdPath
        self.macOSRestoreImagePath = macOSRestoreImagePath
        self.auxiliaryStoragePath = auxiliaryStoragePath
        self.machineIdentifierPath = machineIdentifierPath
    }

    // MARK: - Factory methods

    /// Create a macOS boot configuration.
    /// - Parameters:
    ///   - restoreImagePath: Path to the IPSW file (only needed for initial install).
    ///   - auxiliaryStoragePath: Path to the NVRAM storage file.
    ///   - machineIdentifierPath: Path to the machine identifier file.
    public static func macOS(
        restoreImagePath: String? = nil,
        auxiliaryStoragePath: String,
        machineIdentifierPath: String
    ) -> BootConfig {
        BootConfig(
            mode: .macOS,
            macOSRestoreImagePath: restoreImagePath,
            auxiliaryStoragePath: auxiliaryStoragePath,
            machineIdentifierPath: machineIdentifierPath
        )
    }

    /// Create a UEFI boot configuration (for Linux/Windows guests).
    /// - Parameter storePath: Path to the EFI variable store file.
    public static func uefi(storePath: String) -> BootConfig {
        BootConfig(
            mode: .uefi,
            uefiStorePath: storePath
        )
    }

    /// Create a direct Linux kernel boot configuration.
    /// - Parameters:
    ///   - kernelPath: Path to the uncompressed kernel image (e.g. `Image`).
    ///   - commandLine: Kernel command-line arguments.
    ///   - initrdPath: Optional path to the initrd/initramfs.
    public static func linuxKernel(
        kernelPath: String,
        commandLine: String = "console=hvc0",
        initrdPath: String? = nil
    ) -> BootConfig {
        BootConfig(
            mode: .linuxKernel,
            kernelPath: kernelPath,
            kernelCommandLine: commandLine,
            initrdPath: initrdPath
        )
    }
}

/// The boot mechanism used by the VM.
public enum BootMode: String, Codable, Sendable, CaseIterable {
    /// macOS boot using Apple's Virtualization framework boot loader.
    case macOS

    /// UEFI firmware boot (used for Linux and Windows guests).
    case uefi

    /// Direct Linux kernel boot (bypasses firmware entirely).
    case linuxKernel
}
