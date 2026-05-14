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

    @Test("Decodes QEMU AArch64 UEFI Linux configuration")
    func decodesQEMUAArch64UEFIConfiguration() throws {
        let plist: [String: Any] = [
            "Backend": "QEMU",
            "Information": [
                "Name": "Debian13Xfce",
            ],
            "Drive": [
                [
                    "Identifier": "322E7D2C-D20D-4149-9CC1-E47827E88702",
                    "ImageName": "322E7D2C-D20D-4149-9CC1-E47827E88702.qcow2",
                    "ImageType": "Disk",
                    "Interface": "VirtIO",
                    "ReadOnly": false,
                ],
            ],
            "QEMU": [
                "UEFIBoot": true,
            ],
            "System": [
                "Architecture": "aarch64",
                "CPUCount": 7,
                "MemorySize": 8192,
                "Target": "virt",
                "Boot": [
                    "EfiVariableStoragePath": "efi_vars.fd",
                    "OperatingSystem": "Linux",
                ],
            ],
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(UTMConfigPlist.self, from: data)

        #expect(decoded.isQEMUAArch64Linux)
        #expect(decoded.isQEMUUEFIBoot)
        #expect(decoded.information?.name == "Debian13Xfce")
        #expect(decoded.system?.cpuCount == 7)
        #expect(decoded.system?.memorySize == 8192)
        #expect(decoded.efiVariableStorageRelativePath == "efi_vars.fd")
        #expect(decoded.drive(imageName: "322E7D2C-D20D-4149-9CC1-E47827E88702.qcow2")?.interface == "VirtIO")
    }
}
