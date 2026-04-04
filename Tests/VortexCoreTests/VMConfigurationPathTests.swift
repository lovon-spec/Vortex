// VMConfigurationPathTests.swift -- Tests for VMConfiguration path helpers.
// VortexCoreTests

import Foundation
import Testing
@testable import VortexCore

@Suite("VMConfiguration paths")
struct VMConfigurationPathTests {

    @Test("In-bundle resources are not treated as external")
    func inBundleResourcesAreLocal() {
        let bundlePath = URL(fileURLWithPath: "/tmp/Test.vortexvm", isDirectory: true)
        let config = VMConfiguration.defaultMacOS(
            name: "Local",
            diskImagePath: bundlePath.appendingPathComponent("disks/boot.img").path,
            auxiliaryStoragePath: bundlePath.appendingPathComponent("auxiliary/AuxiliaryStorage").path,
            machineIdentifierPath: bundlePath.appendingPathComponent("auxiliary/machineIdentifier.bin").path,
            hardwareModelPath: bundlePath.appendingPathComponent("auxiliary/hardwareModel.bin").path
        )

        #expect(!config.usesExternalResources(bundlePath: bundlePath))
    }

    @Test("External disk path marks VM as external")
    func externalDiskPathIsDetected() {
        let bundlePath = URL(fileURLWithPath: "/tmp/Test.vortexvm", isDirectory: true)
        let config = VMConfiguration.defaultMacOS(
            name: "External",
            diskImagePath: "/Users/shared/macOS.utm/Data/BOOT-FIXED-0001.img",
            auxiliaryStoragePath: "/Users/shared/macOS.utm/Data/AuxiliaryStorage",
            machineIdentifierPath: bundlePath.appendingPathComponent("auxiliary/machineIdentifier.bin").path,
            hardwareModelPath: bundlePath.appendingPathComponent("auxiliary/hardwareModel.bin").path
        )

        #expect(config.usesExternalResources(bundlePath: bundlePath))
    }

    @Test("Symlinked in-bundle disk still counts as external")
    func symlinkedDiskPathIsDetected() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("VortexCoreTests-\(UUID().uuidString)", isDirectory: true)
        let bundlePath = root.appendingPathComponent("Shared.vortexvm", isDirectory: true)
        let disksPath = bundlePath.appendingPathComponent("disks", isDirectory: true)
        let externalDir = root.appendingPathComponent("UTM", isDirectory: true)
        let externalDisk = externalDir.appendingPathComponent("BOOT-FIXED-0001.img")
        let symlinkedDisk = disksPath.appendingPathComponent("boot.img")

        try fm.createDirectory(at: disksPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalDir, withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: externalDisk.path, contents: Data(), attributes: nil))
        try fm.createSymbolicLink(at: symlinkedDisk, withDestinationURL: externalDisk)
        defer { try? fm.removeItem(at: root) }

        let config = VMConfiguration.defaultMacOS(
            name: "Symlinked",
            diskImagePath: symlinkedDisk.path,
            auxiliaryStoragePath: bundlePath.appendingPathComponent("auxiliary/AuxiliaryStorage").path,
            machineIdentifierPath: bundlePath.appendingPathComponent("auxiliary/machineIdentifier.bin").path,
            hardwareModelPath: bundlePath.appendingPathComponent("auxiliary/hardwareModel.bin").path
        )

        #expect(config.usesExternalResources(bundlePath: bundlePath))
    }
}
