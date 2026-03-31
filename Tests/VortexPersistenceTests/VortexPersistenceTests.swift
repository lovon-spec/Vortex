// VortexPersistenceTests.swift — Tests for VortexPersistence module.
// VortexPersistenceTests

import Testing
import Foundation
@testable import VortexCore
@testable import VortexPersistence

// MARK: - VMConfigCodec Tests

@Suite("VMConfigCodec")
struct VMConfigCodecTests {

    @Test("Round-trip encode and decode preserves all fields")
    func encodeDecodeRoundTrip() throws {
        let config = VMConfiguration.defaultLinux(
            name: "Test VM",
            diskImagePath: "/tmp/disk.img",
            diskSizeGiB: 32,
            efiStorePath: "/tmp/efi.store"
        )

        let data = try VMConfigCodec.encode(config)
        let decoded = try VMConfigCodec.decode(VMConfiguration.self, from: data)

        #expect(decoded.id == config.id)
        #expect(decoded.identity.name == "Test VM")
        #expect(decoded.guestOS == .linuxARM64)
        #expect(decoded.storage.disks.count == 1)
        #expect(decoded.bootConfig.mode == .uefi)
    }

    @Test("Encoder output is pretty-printed without escaped slashes")
    func encoderOutputIsPrettyPrinted() throws {
        let config = VMConfiguration.defaultLinux(
            name: "Pretty",
            diskImagePath: "/tmp/disk.img",
            diskSizeGiB: 16,
            efiStorePath: "/tmp/efi.store"
        )

        let data = try VMConfigCodec.encode(config)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("\n"))
        #expect(!jsonString.contains("\\/"))
    }

    @Test("Decoding invalid data throws persistenceFailed")
    func decodeInvalidDataThrows() {
        let garbage = Data("not json".utf8)

        #expect(throws: VortexError.self) {
            try VMConfigCodec.decode(VMConfiguration.self, from: garbage)
        }
    }

    @Test("Base64 round-trip preserves binary data")
    func base64RoundTrip() throws {
        let original = Data([0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF])
        let encoded = VMConfigCodec.base64Encode(original)
        let decoded = try VMConfigCodec.base64Decode(encoded)
        #expect(original == decoded)
    }

    @Test("Base64 decode of invalid string throws")
    func base64DecodeInvalidStringThrows() {
        #expect(throws: VortexError.self) {
            try VMConfigCodec.base64Decode("!!!not-base64!!!")
        }
    }
}

// MARK: - VMFileManager Tests

@Suite("VMFileManager")
struct VMFileManagerTests {

    /// Creates a temporary directory and VMFileManager for a single test.
    private func makeSUT() throws -> (sut: VMFileManager, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (VMFileManager(baseDirectory: tempDir), tempDir)
    }

    private func cleanup(_ tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeTestConfig() -> VMConfiguration {
        VMConfiguration.defaultLinux(
            name: "Test-\(UUID().uuidString.prefix(8))",
            diskImagePath: "/tmp/test-disk.img",
            diskSizeGiB: 16,
            efiStorePath: "/tmp/test-efi.store"
        )
    }

    @Test("Bundle path has correct format")
    func vmBundlePathFormat() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let id = UUID()
        let path = sut.vmBundlePath(for: id)
        #expect(path.lastPathComponent.hasSuffix(".vortexvm"))
        #expect(path.lastPathComponent.hasPrefix(id.uuidString))
    }

    @Test("Creating a bundle creates full directory structure and config.json")
    func createVMBundleCreatesDirectoryStructure() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        let bundlePath = try sut.createVMBundle(for: config)

        #expect(FileManager.default.fileExists(atPath: bundlePath.path))

        for subdir in VMFileManager.Subdirectory.allCases {
            let subdirPath = sut.subdirectoryPath(subdir, for: config.id)
            var isDir: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: subdirPath.path, isDirectory: &isDir),
                "Missing subdirectory: \(subdir.rawValue)"
            )
            #expect(isDir.boolValue)
        }

        let configPath = sut.configFilePath(for: config.id)
        #expect(FileManager.default.fileExists(atPath: configPath.path))

        let data = try Data(contentsOf: configPath)
        let decoded = try VMConfigCodec.decode(VMConfiguration.self, from: data)
        #expect(decoded.id == config.id)
    }

    @Test("Creating a bundle twice throws fileAlreadyExists")
    func createVMBundleThrowsIfAlreadyExists() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        try sut.createVMBundle(for: config)

        #expect(throws: VortexError.self) {
            try sut.createVMBundle(for: config)
        }
    }

    @Test("Deleting a bundle removes it from disk")
    func deleteVMBundle() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        try sut.createVMBundle(for: config)
        #expect(sut.bundleExists(for: config.id))

        try sut.deleteVMBundle(id: config.id)
        #expect(!sut.bundleExists(for: config.id))
    }

    @Test("Deleting a non-existent bundle throws vmNotFound")
    func deleteVMBundleThrowsIfNotFound() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        #expect(throws: VortexError.self) {
            try sut.deleteVMBundle(id: UUID())
        }
    }

    @Test("Listing bundles returns all .vortexvm directories")
    func listVMBundles() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        try sut.createVMBundle(for: makeTestConfig())
        try sut.createVMBundle(for: makeTestConfig())

        let bundles = try sut.listVMBundles()
        #expect(bundles.count == 2)
        #expect(bundles.allSatisfy { $0.pathExtension == VMFileManager.bundleExtension })
    }

    @Test("Listing bundles with no base directory returns empty array")
    func listVMBundlesReturnsEmptyWhenNoBaseDir() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let mgr = VMFileManager(baseDirectory: tempDir)

        let bundles = try mgr.listVMBundles()
        #expect(bundles.isEmpty)
    }

    @Test("bundleExists returns correct results before and after creation")
    func bundleExists() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        #expect(!sut.bundleExists(for: config.id))
        try sut.createVMBundle(for: config)
        #expect(sut.bundleExists(for: config.id))
    }

    @Test("diskPath returns path within disks/ subdirectory")
    func diskPathLocation() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let id = UUID()
        let path = sut.diskPath(vmID: id, diskName: "boot.img")
        #expect(path.lastPathComponent == "boot.img")
        #expect(path.path.contains("disks"))
    }

    @Test("Creating a disk image produces a file with correct logical size")
    func createDiskImage() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        try sut.createVMBundle(for: config)

        let diskURL = sut.diskPath(vmID: config.id, diskName: "test.img")
        let sizeBytes: UInt64 = 1024 * 1024

        try sut.createDiskImage(at: diskURL, sizeInBytes: sizeBytes)

        #expect(FileManager.default.fileExists(atPath: diskURL.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: diskURL.path)
        let fileSize = attrs[.size] as? UInt64
        #expect(fileSize == sizeBytes)
    }

    @Test("Creating a disk image at an existing path throws fileAlreadyExists")
    func createDiskImageThrowsIfAlreadyExists() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        try sut.createVMBundle(for: config)

        let diskURL = sut.diskPath(vmID: config.id, diskName: "test.img")
        try sut.createDiskImage(at: diskURL, sizeInBytes: 1024)

        #expect(throws: VortexError.self) {
            try sut.createDiskImage(at: diskURL, sizeInBytes: 1024)
        }
    }

    @Test("ensureBaseDirectoryExists creates directory and is idempotent")
    func ensureBaseDirectoryExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexBaseTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let newBase = tempDir.appendingPathComponent("new-base", isDirectory: true)
        let mgr = VMFileManager(baseDirectory: newBase)

        #expect(!FileManager.default.fileExists(atPath: newBase.path))
        try mgr.ensureBaseDirectoryExists()
        #expect(FileManager.default.fileExists(atPath: newBase.path))

        // Should not throw on second call.
        try mgr.ensureBaseDirectoryExists()
    }
}

// MARK: - VMRepository Tests

@Suite("VMRepository")
struct VMRepositoryTests {

    private func makeSUT() throws -> (sut: VMRepository, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexRepoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileMgr = VMFileManager(baseDirectory: tempDir)
        return (VMRepository(fileManager: fileMgr), tempDir)
    }

    private func cleanup(_ tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeTestConfig(name: String) -> VMConfiguration {
        VMConfiguration.defaultLinux(
            name: name,
            diskImagePath: "/tmp/test-disk.img",
            diskSizeGiB: 16,
            efiStorePath: "/tmp/test-efi.store"
        )
    }

    @Test("Save and load preserves configuration")
    func saveAndLoad() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "SaveLoad")
        try sut.save(config)

        let loaded = try sut.load(id: config.id)
        #expect(loaded.id == config.id)
        #expect(loaded.identity.name == "SaveLoad")
    }

    @Test("Save overwrites existing configuration")
    func saveOverwritesExistingConfig() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        var config = makeTestConfig(name: "Original")
        try sut.save(config)

        config.identity.name = "Updated"
        try sut.save(config)

        let loaded = try sut.load(id: config.id)
        #expect(loaded.identity.name == "Updated")
    }

    @Test("Loading a missing VM throws vmNotFound")
    func loadThrowsForMissingVM() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        #expect(throws: VortexError.self) {
            try sut.load(id: UUID())
        }
    }

    @Test("loadAll returns all saved configurations")
    func loadAll() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        try sut.save(makeTestConfig(name: "VM-A"))
        try sut.save(makeTestConfig(name: "VM-B"))

        let all = try sut.loadAll()
        #expect(all.count == 2)
    }

    @Test("loadAll sorts by modifiedAt descending")
    func loadAllSortsByModifiedAt() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let older = VMConfiguration.defaultLinux(
            name: "Older",
            diskImagePath: "/tmp/a.img",
            diskSizeGiB: 16,
            efiStorePath: "/tmp/a.efi"
        )
        try sut.save(older)

        let newer = VMConfiguration(
            identity: VMIdentity(name: "Newer"),
            guestOS: .linuxARM64,
            storage: StorageConfiguration(disks: [
                .bootDisk(imagePath: "/tmp/b.img", sizeGiB: 16)
            ]),
            bootConfig: .uefi(storePath: "/tmp/b.efi"),
            modifiedAt: Date().addingTimeInterval(10)
        )
        try sut.save(newer)

        let all = try sut.loadAll()
        #expect(all.first?.identity.name == "Newer")
        #expect(all.last?.identity.name == "Older")
    }

    @Test("Delete removes bundle from disk")
    func delete() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "ToDelete")
        try sut.save(config)
        #expect(sut.exists(id: config.id))

        try sut.delete(id: config.id)
        #expect(!sut.exists(id: config.id))
    }

    @Test("Update bumps modifiedAt timestamp")
    func updateBumpsModifiedDate() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "Original")
        try sut.save(config)

        let originalDate = config.modifiedAt

        var updated = config
        updated.identity.name = "Modified"
        try sut.update(updated)

        let loaded = try sut.load(id: config.id)
        #expect(loaded.identity.name == "Modified")
        #expect(loaded.modifiedAt >= originalDate)
    }

    @Test("Update throws vmNotFound for missing VM")
    func updateThrowsForMissingVM() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "Ghost")

        #expect(throws: VortexError.self) {
            try sut.update(config)
        }
    }

    @Test("exists returns correct state")
    func exists() throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "ExistCheck")
        #expect(!sut.exists(id: config.id))
        try sut.save(config)
        #expect(sut.exists(id: config.id))
    }
}

// MARK: - SnapshotRepository Tests

@Suite("SnapshotRepository")
struct SnapshotRepositoryTests {

    private func makeSUT() throws -> (sut: SnapshotRepository, fileMgr: VMFileManager, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileMgr = VMFileManager(baseDirectory: tempDir)
        return (SnapshotRepository(fileManager: fileMgr), fileMgr, tempDir)
    }

    private func cleanup(_ tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeTestConfig() -> VMConfiguration {
        VMConfiguration.defaultLinux(
            name: "SnapshotTest-\(UUID().uuidString.prefix(8))",
            diskImagePath: "/tmp/snap-disk.img",
            diskSizeGiB: 16,
            efiStorePath: "/tmp/snap-efi.store"
        )
    }

    private func makeVMWithDisk(
        sut: SnapshotRepository,
        fileMgr: VMFileManager
    ) throws -> VMConfiguration {
        let config = makeTestConfig()
        try fileMgr.createVMBundle(for: config)
        let diskURL = fileMgr.diskPath(vmID: config.id, diskName: "boot.img")
        try fileMgr.createDiskImage(at: diskURL, sizeInBytes: 4096)
        return config
    }

    @Test("Creating a snapshot clones disk and writes metadata")
    func createSnapshot() throws {
        let (sut, fileMgr, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = try makeVMWithDisk(sut: sut, fileMgr: fileMgr)
        let snapshot = try sut.createSnapshot(for: config.id, name: "snap-1")

        #expect(snapshot.vmID == config.id)
        #expect(snapshot.name == "snap-1")
        #expect(snapshot.sizeBytes != nil)

        let snapshotDir = fileMgr.snapshotPath(snapshotID: snapshot.id, for: config.id)
        #expect(FileManager.default.fileExists(atPath: snapshotDir.path))

        let metadataPath = snapshotDir.appendingPathComponent("metadata.json")
        #expect(FileManager.default.fileExists(atPath: metadataPath.path))

        let clonedDisk = snapshotDir
            .appendingPathComponent("disks", isDirectory: true)
            .appendingPathComponent("boot.img")
        #expect(FileManager.default.fileExists(atPath: clonedDisk.path))
    }

    @Test("Creating a snapshot for a missing VM throws vmNotFound")
    func createSnapshotThrowsForMissingVM() throws {
        let (sut, _, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        #expect(throws: VortexError.self) {
            try sut.createSnapshot(for: UUID(), name: "nope")
        }
    }

    @Test("Listing snapshots returns all in newest-first order")
    func listSnapshots() throws {
        let (sut, fileMgr, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = try makeVMWithDisk(sut: sut, fileMgr: fileMgr)
        try sut.createSnapshot(for: config.id, name: "snap-1")
        try sut.createSnapshot(for: config.id, name: "snap-2")

        let snapshots = try sut.listSnapshots(for: config.id)
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.name == "snap-2")
        #expect(snapshots.last?.name == "snap-1")
    }

    @Test("Listing snapshots for a VM with none returns empty array")
    func listSnapshotsReturnsEmptyForNoSnapshots() throws {
        let (sut, fileMgr, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        try fileMgr.createVMBundle(for: config)

        let snapshots = try sut.listSnapshots(for: config.id)
        #expect(snapshots.isEmpty)
    }

    @Test("Deleting a snapshot removes its directory")
    func deleteSnapshot() throws {
        let (sut, fileMgr, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = try makeVMWithDisk(sut: sut, fileMgr: fileMgr)
        let snapshot = try sut.createSnapshot(for: config.id, name: "to-delete")

        let snapshotDir = fileMgr.snapshotPath(snapshotID: snapshot.id, for: config.id)
        #expect(FileManager.default.fileExists(atPath: snapshotDir.path))

        try sut.deleteSnapshot(snapshot.id, for: config.id)
        #expect(!FileManager.default.fileExists(atPath: snapshotDir.path))
    }

    @Test("Deleting a non-existent snapshot throws snapshotFailed")
    func deleteSnapshotThrowsForMissing() throws {
        let (sut, _, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        #expect(throws: VortexError.self) {
            try sut.deleteSnapshot(UUID(), for: UUID())
        }
    }

    @Test("Restoring a snapshot replaces disk content")
    func restoreSnapshot() throws {
        let (sut, fileMgr, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = try makeVMWithDisk(sut: sut, fileMgr: fileMgr)
        let diskURL = fileMgr.diskPath(vmID: config.id, diskName: "boot.img")

        // Write identifiable content to the original disk.
        let originalContent = Data(repeating: 0xAA, count: 1024)
        try originalContent.write(to: diskURL)

        // Snapshot.
        let snapshot = try sut.createSnapshot(for: config.id, name: "baseline")

        // Modify the disk.
        let modifiedContent = Data(repeating: 0xBB, count: 1024)
        try modifiedContent.write(to: diskURL)
        #expect(try Data(contentsOf: diskURL) == modifiedContent)

        // Restore.
        try sut.restoreSnapshot(snapshot.id, for: config.id)

        let restoredContent = try Data(contentsOf: diskURL)
        #expect(restoredContent == originalContent)
    }

    @Test("Restoring a snapshot for a missing VM throws vmNotFound")
    func restoreSnapshotThrowsForMissingVM() throws {
        let (sut, _, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        #expect(throws: VortexError.self) {
            try sut.restoreSnapshot(UUID(), for: UUID())
        }
    }

    @Test("Restoring a non-existent snapshot throws snapshotFailed")
    func restoreSnapshotThrowsForMissingSnapshot() throws {
        let (sut, fileMgr, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig()
        try fileMgr.createVMBundle(for: config)

        #expect(throws: VortexError.self) {
            try sut.restoreSnapshot(UUID(), for: config.id)
        }
    }
}

// MARK: - TemplateRepository Tests

@Suite("TemplateRepository")
struct TemplateRepositoryTests {

    private let sut = TemplateRepository()

    @Test("All templates returns three built-in templates")
    func allTemplatesReturnsThree() {
        let templates = sut.allTemplates()
        #expect(templates.count == 3)
    }

    @Test("All templates cover all GuestOS types")
    func allTemplatesCoverAllGuestOSTypes() {
        let templates = sut.allTemplates()
        let guestOSTypes = Set(templates.map(\.guestOS))
        #expect(guestOSTypes.contains(.macOS))
        #expect(guestOSTypes.contains(.linuxARM64))
        #expect(guestOSTypes.contains(.windowsARM))
    }

    @Test("Filter templates by guest OS")
    func templatesByGuestOS() {
        let macTemplates = sut.templates(for: .macOS)
        #expect(!macTemplates.isEmpty)
        #expect(macTemplates.allSatisfy { $0.guestOS == .macOS })

        let linuxTemplates = sut.templates(for: .linuxARM64)
        #expect(!linuxTemplates.isEmpty)
        #expect(linuxTemplates.allSatisfy { $0.guestOS == .linuxARM64 })
    }

    @Test("Find template by ID")
    func findTemplateByID() {
        let found = sut.template(withID: "macos-sequoia")
        #expect(found != nil)
        #expect(found?.guestOS == .macOS)

        let notFound = sut.template(withID: "nonexistent")
        #expect(notFound == nil)
    }

    @Test("Create VM from macOS template")
    func createVMFromMacOSTemplate() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexTemplateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileMgr = VMFileManager(baseDirectory: tempDir)
        let config = sut.createVM(from: .macOSSequoia, name: "My macOS VM", fileManager: fileMgr)

        #expect(config.identity.name == "My macOS VM")
        #expect(config.guestOS == .macOS)
        #expect(config.hardware.cpuCoreCount == 4)
        #expect(config.bootConfig.mode == .macOS)
        #expect(config.bootConfig.auxiliaryStoragePath != nil)
        #expect(config.bootConfig.machineIdentifierPath != nil)
        #expect(config.clipboard.enabled == true)
        #expect(config.storage.disks.count == 1)
        #expect(config.storage.disks.first?.sizeBytes == 64 * 1024 * 1024 * 1024)
    }

    @Test("Create VM from Linux template")
    func createVMFromLinuxTemplate() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexTemplateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileMgr = VMFileManager(baseDirectory: tempDir)
        let config = sut.createVM(from: .ubuntu2404, name: "My Ubuntu VM", fileManager: fileMgr)

        #expect(config.identity.name == "My Ubuntu VM")
        #expect(config.guestOS == .linuxARM64)
        #expect(config.hardware.cpuCoreCount == 4)
        #expect(config.hardware.memorySize == 4 * 1024 * 1024 * 1024)
        #expect(config.bootConfig.mode == .uefi)
        #expect(config.bootConfig.uefiStorePath != nil)
        #expect(config.clipboard.enabled == false)
        #expect(config.rosetta?.enabled == false)
        #expect(config.storage.disks.first?.sizeBytes == 32 * 1024 * 1024 * 1024)
    }

    @Test("Create VM from Windows template")
    func createVMFromWindowsTemplate() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexTemplateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileMgr = VMFileManager(baseDirectory: tempDir)
        let config = sut.createVM(from: .windows11ARM, name: "My Win VM", fileManager: fileMgr)

        #expect(config.identity.name == "My Win VM")
        #expect(config.guestOS == .windowsARM)
        #expect(config.bootConfig.mode == .uefi)
        #expect(config.storage.disks.first?.sizeBytes == 64 * 1024 * 1024 * 1024)
    }

    @Test("All templates produce valid VMConfigurations")
    func createVMProducesValidConfiguration() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexTemplateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileMgr = VMFileManager(baseDirectory: tempDir)

        for template in sut.allTemplates() {
            let config = sut.createVM(from: template, name: template.name, fileManager: fileMgr)
            let issues = config.validate()
            #expect(issues.isEmpty, "Template '\(template.name)' produced invalid config: \(issues)")
        }
    }

    @Test("Creating VMs from same template produces unique IDs")
    func createVMProducesUniqueIDs() {
        let config1 = sut.createVM(from: .macOSSequoia, name: "VM 1")
        let config2 = sut.createVM(from: .macOSSequoia, name: "VM 2")
        #expect(config1.id != config2.id)
    }
}

// MARK: - DiskPersistenceStore Tests

@Suite("DiskPersistenceStore")
struct DiskPersistenceStoreTests {

    private func makeSUT() throws -> (sut: DiskPersistenceStore, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileMgr = VMFileManager(baseDirectory: tempDir)
        let vmRepo = VMRepository(fileManager: fileMgr)
        let snapRepo = SnapshotRepository(fileManager: fileMgr)
        return (DiskPersistenceStore(vmRepository: vmRepo, snapshotRepository: snapRepo), tempDir)
    }

    private func cleanup(_ tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeTestConfig(name: String) -> VMConfiguration {
        VMConfiguration.defaultLinux(
            name: name,
            diskImagePath: "/tmp/store-disk.img",
            diskSizeGiB: 16,
            efiStorePath: "/tmp/store-efi.store"
        )
    }

    @Test("Async save and load round-trip")
    func asyncSaveAndLoad() async throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "AsyncTest")
        try await sut.save(config)

        let loaded = try await sut.load(id: config.id)
        #expect(loaded != nil)
        #expect(loaded?.id == config.id)
    }

    @Test("Async load returns nil for missing VM")
    func asyncLoadReturnsNilForMissing() async throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let result = try await sut.load(id: UUID())
        #expect(result == nil)
    }

    @Test("Async listAll returns all saved configurations")
    func asyncListAll() async throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        try await sut.save(makeTestConfig(name: "A"))
        try await sut.save(makeTestConfig(name: "B"))

        let all = try await sut.listAll()
        #expect(all.count == 2)
    }

    @Test("Async delete removes VM")
    func asyncDelete() async throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "ToDelete")
        try await sut.save(config)
        #expect(try await sut.exists(id: config.id))

        try await sut.delete(id: config.id)
        #expect(try await !sut.exists(id: config.id))
    }

    @Test("Async exists tracks state correctly")
    func asyncExists() async throws {
        let (sut, tempDir) = try makeSUT()
        defer { cleanup(tempDir) }

        let config = makeTestConfig(name: "ExistCheck")
        #expect(try await !sut.exists(id: config.id))

        try await sut.save(config)
        #expect(try await sut.exists(id: config.id))
    }
}
