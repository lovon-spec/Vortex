// UTMConfigPlistTests.swift -- Tests for decoding UTM config.plist files.
// VortexPersistenceTests

import Foundation
import Testing
@testable import VortexPersistence

@Suite("UTMConfigPlist")
struct UTMConfigPlistTests {

    @Test("Decodes embedded macOS platform identity from UTM config")
    func decodesEmbeddedMacPlatformIdentity() throws {
        let hardwareModel = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30])
        let machineIdentifier = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60])

        let plist: [String: Any] = [
            "Information": [
                "Name": "macOS",
            ],
            "System": [
                "Boot": [
                    "OperatingSystem": "macOS",
                ],
                "MacPlatform": [
                    "AuxiliaryStoragePath": "AuxiliaryStorage",
                    "HardwareModel": hardwareModel,
                    "MachineIdentifier": machineIdentifier,
                ],
            ],
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(UTMConfigPlist.self, from: data)

        #expect(decoded.isMacOS)
        #expect(decoded.information?.name == "macOS")
        #expect(decoded.auxiliaryStorageRelativePath == "AuxiliaryStorage")
        #expect(decoded.embeddedHardwareModelData == hardwareModel)
        #expect(decoded.embeddedMachineIdentifierData == machineIdentifier)
    }

    @Test("Falls back to legacy Virtualization.MacAuxiliaryStorage key")
    func fallsBackToLegacyAuxiliaryStorageKey() throws {
        let plist: [String: Any] = [
            "Virtualization": [
                "MacAuxiliaryStorage": "Data/AuxiliaryStorage",
            ],
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(UTMConfigPlist.self, from: data)

        #expect(decoded.auxiliaryStorageRelativePath == "Data/AuxiliaryStorage")
        #expect(!decoded.isMacOS)
    }
}
