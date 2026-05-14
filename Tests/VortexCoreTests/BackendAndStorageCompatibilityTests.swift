// BackendAndStorageCompatibilityTests.swift -- Compatibility coverage for backend/storage additions.
// VortexCoreTests

import Foundation
import Testing
@testable import VortexCore

@Suite("Backend and storage compatibility")
struct BackendAndStorageCompatibilityTests {

    @Test("Legacy VM JSON defaults backend and disk image format")
    func legacyJSONDefaultsBackendAndImageFormat() throws {
        let config = VMConfiguration.defaultLinux(
            name: "Legacy Linux",
            diskImagePath: "/Users/shared/Linux.utm/Data/disk-0.qcow2",
            efiStorePath: "/Users/shared/Linux.utm/Data/efi-vars.fd"
        )

        let encoded = try JSONEncoder().encode(config)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "backend")

        var storage = try #require(root["storage"] as? [String: Any])
        var disks = try #require(storage["disks"] as? [[String: Any]])
        disks[0].removeValue(forKey: "imageFormat")
        storage["disks"] = disks
        root["storage"] = storage

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: legacyData)

        #expect(decoded.backend == .appleVirtualization)
        #expect(decoded.storage.bootDisk?.imageFormat == .auto)
        #expect(decoded.storage.bootDisk?.resolvedImageFormat == .qcow2)
    }

    @Test("Disk image format resolves by explicit value or path extension")
    func diskImageFormatResolution() {
        #expect(DiskImageFormat.auto.resolved(forPath: "/vm/disk.raw") == .raw)
        #expect(DiskImageFormat.auto.resolved(forPath: "/vm/disk.img") == .raw)
        #expect(DiskImageFormat.auto.resolved(forPath: "/vm/disk.qcow2") == .qcow2)
        #expect(DiskImageFormat.raw.resolved(forPath: "/vm/disk.qcow2") == .raw)
        #expect(DiskImageFormat.qcow2.resolved(forPath: "/vm/disk.img") == .qcow2)
    }

    @Test("VortexHV validation is scoped to direct Linux ARM64")
    func vortexHVValidationScope() {
        let linux = VMConfiguration(
            identity: VMIdentity(name: "Native Linux", iconName: "pc"),
            guestOS: .linuxARM64,
            backend: .vortexHV,
            storage: StorageConfiguration(disks: [
                DiskConfig(
                    label: "Boot Disk",
                    imagePath: "/vm/linux.qcow2",
                    imageFormat: .qcow2,
                    sizeBytes: 8 * 1024 * 1024 * 1024
                )
            ]),
            network: .none,
            display: .standard,
            audio: .disabled,
            clipboard: .disabled,
            bootConfig: .linuxKernel(
                kernelPath: "/vm/Image",
                commandLine: "console=ttyAMA0 root=/dev/vda2",
                initrdPath: nil
            )
        )

        #expect(linux.validate().isEmpty)

        var mac = VMConfiguration.defaultMacOS(
            name: "macOS",
            diskImagePath: "/vm/mac.img",
            auxiliaryStoragePath: "/vm/aux",
            machineIdentifierPath: "/vm/machine.bin"
        )
        mac.backend = .vortexHV

        let issues = mac.validate()
        #expect(issues.contains("VortexHV backend currently supports Linux ARM64 guests."))
        #expect(issues.contains("VortexHV backend cannot use macOS boot mode."))
    }
}
