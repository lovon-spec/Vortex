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

    public struct Information: Decodable, Sendable {
        public let name: String?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
        }
    }

    public struct System: Decodable, Sendable {
        public struct Boot: Decodable, Sendable {
            public let operatingSystem: String?

            enum CodingKeys: String, CodingKey {
                case operatingSystem = "OperatingSystem"
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
        public let cpuCount: Int?
        public let macPlatform: MacPlatform?
        public let memorySize: Int?

        enum CodingKeys: String, CodingKey {
            case boot = "Boot"
            case cpuCount = "CPUCount"
            case macPlatform = "MacPlatform"
            case memorySize = "MemorySize"
        }
    }

    public struct Virtualization: Decodable, Sendable {
        public let macAuxiliaryStorage: String?

        enum CodingKeys: String, CodingKey {
            case macAuxiliaryStorage = "MacAuxiliaryStorage"
        }
    }

    public let information: Information?
    public let system: System?
    public let virtualization: Virtualization?

    enum CodingKeys: String, CodingKey {
        case information = "Information"
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

    /// Auxiliary storage path relative to the bundle's `Data/` directory.
    public var auxiliaryStorageRelativePath: String? {
        system?.macPlatform?.auxiliaryStoragePath ?? virtualization?.macAuxiliaryStorage
    }

    public var embeddedHardwareModelData: Data? {
        system?.macPlatform?.hardwareModel
    }

    public var embeddedMachineIdentifierData: Data? {
        system?.macPlatform?.machineIdentifier
    }
}
