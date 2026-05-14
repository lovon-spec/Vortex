// UTMConfigPlist.swift -- Decoding helpers for UTM config.plist files.
// VortexPersistence

import Foundation

/// Minimal decoder for the parts of UTM's `config.plist` needed by Vortex import.
///
/// UTM's Apple Virtualization backend stores macOS platform identity in
/// `System.MacPlatform`:
/// - `AuxiliaryStoragePath` (relative path inside the bundle's `Data/` directory)
/// - `HardwareModel` (`VZMacHardwareModel.dataRepresentation`)
/// - `MachineIdentifier` (`VZMacMachineIdentifier.dataRepresentation`)
///
/// Older layouts may also expose the auxiliary storage path under
/// `Virtualization.MacAuxiliaryStorage`.
public struct UTMConfigPlist: Decodable, Sendable {
    public struct Drive: Decodable, Sendable {
        public let identifier: String?
        public let imageName: String?
        public let imageType: String?
        public let interface: String?
        public let readOnly: Bool?

        enum CodingKeys: String, CodingKey {
            case identifier = "Identifier"
            case imageName = "ImageName"
            case imageType = "ImageType"
            case interface = "Interface"
            case readOnly = "ReadOnly"
        }
    }

    public struct Information: Decodable, Sendable {
        public let name: String?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
        }
    }

    public struct System: Decodable, Sendable {
        public struct Boot: Decodable, Sendable {
            public let operatingSystem: String?
            public let efiVariableStoragePath: String?

            enum CodingKeys: String, CodingKey {
                case operatingSystem = "OperatingSystem"
                case efiVariableStoragePath = "EfiVariableStoragePath"
            }
        }

        public struct MacPlatform: Decodable, Sendable {
            public let auxiliaryStoragePath: String?
            public let hardwareModel: Data?
            public let machineIdentifier: Data?

            enum CodingKeys: String, CodingKey {
                case auxiliaryStoragePath = "AuxiliaryStoragePath"
                case hardwareModel = "HardwareModel"
                case machineIdentifier = "MachineIdentifier"
            }
        }

        public let boot: Boot?
        public let architecture: String?
        public let cpuCount: Int?
        public let macPlatform: MacPlatform?
        public let memorySize: Int?
        public let target: String?

        enum CodingKeys: String, CodingKey {
            case boot = "Boot"
            case architecture = "Architecture"
            case cpuCount = "CPUCount"
            case macPlatform = "MacPlatform"
            case memorySize = "MemorySize"
            case target = "Target"
        }
    }

    public struct QEMU: Decodable, Sendable {
        public let uefiBoot: Bool?

        enum CodingKeys: String, CodingKey {
            case uefiBoot = "UEFIBoot"
        }
    }

    public struct Virtualization: Decodable, Sendable {
        public let macAuxiliaryStorage: String?

        enum CodingKeys: String, CodingKey {
            case macAuxiliaryStorage = "MacAuxiliaryStorage"
        }
    }

    public let information: Information?
    public let backend: String?
    public let drives: [Drive]?
    public let qemu: QEMU?
    public let system: System?
    public let virtualization: Virtualization?

    enum CodingKeys: String, CodingKey {
        case information = "Information"
        case backend = "Backend"
        case drives = "Drive"
        case qemu = "QEMU"
        case system = "System"
        case virtualization = "Virtualization"
    }

    public static func load(from url: URL) throws -> UTMConfigPlist {
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(Self.self, from: data)
    }

    /// True when the config appears to describe a macOS VM backed by Apple's VZ stack.
    public var isMacOS: Bool {
        system?.boot?.operatingSystem == "macOS" || system?.macPlatform != nil
    }

    /// True when the config appears to describe a QEMU AArch64 Linux `virt` VM.
    public var isQEMUAArch64Linux: Bool {
        backend == "QEMU"
            && system?.architecture == "aarch64"
            && (system?.target == nil || system?.target == "virt")
            && !isMacOS
    }

    public var isQEMUUEFIBoot: Bool {
        qemu?.uefiBoot == true || system?.boot?.efiVariableStoragePath != nil
    }

    /// Auxiliary storage path relative to the bundle's `Data/` directory.
    public var auxiliaryStorageRelativePath: String? {
        system?.macPlatform?.auxiliaryStoragePath ?? virtualization?.macAuxiliaryStorage
    }

    /// EFI variable store path relative to the bundle's `Data/` directory.
    public var efiVariableStorageRelativePath: String? {
        system?.boot?.efiVariableStoragePath
    }

    /// Return the UTM drive entry matching a selected disk image path.
    public func drive(imageName: String) -> Drive? {
        drives?.first { $0.imageName == imageName }
    }

    public var embeddedHardwareModelData: Data? {
        system?.macPlatform?.hardwareModel
    }

    public var embeddedMachineIdentifierData: Data? {
        system?.macPlatform?.machineIdentifier
    }
}
