// CreateVMCommand.swift — Create a new macOS VM bundle with disk image.
// VortexCLI
//
// Creates a VM configuration, persists it to disk as a .vortexvm bundle,
// and creates a sparse disk image of the requested size.
//
// Usage:
//   vortex create-vm --name "My macOS VM" --cpu 4 --memory 8192 --disk 64

import ArgumentParser
import Foundation
import VortexCore
import VortexPersistence

struct CreateVMCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "create-vm",
        abstract: "Create a new macOS virtual machine.",
        discussion: """
            Creates a VM bundle in ~/Library/Application Support/Vortex/VirtualMachines/ \
            containing the configuration JSON, a sparse disk image, and the directory \
            structure needed for macOS installation and boot.

            After creation, use 'vortex install-macos --vm <id>' to install macOS \
            into the VM.
            """
    )

    @Option(
        name: .long,
        help: "Display name for the virtual machine."
    )
    var name: String

    @Option(
        name: .long,
        help: "Number of CPU cores to allocate (default: 4)."
    )
    var cpu: Int = 4

    @Option(
        name: .long,
        help: "Memory in MiB to allocate (default: 8192 = 8 GiB)."
    )
    var memory: UInt64 = 8192

    @Option(
        name: .long,
        help: "Boot disk size in GiB (default: 64)."
    )
    var disk: UInt64 = 64

    // MARK: - Run

    func run() async throws {
        let fileManager = VMFileManager()
        let repository = VMRepository(fileManager: fileManager)

        // Ensure the base directory exists.
        try fileManager.ensureBaseDirectoryExists()

        // Generate a new VM identity.
        let vmID = UUID()
        let bundlePath = fileManager.vmBundlePath(for: vmID)
        let disksDir = fileManager.subdirectoryPath(.disks, for: vmID)
        let auxDir = fileManager.subdirectoryPath(.auxiliary, for: vmID)

        // Resolve paths for disk image and macOS auxiliary storage.
        let diskImagePath = disksDir.appendingPathComponent("boot.img").path
        let auxStoragePath = auxDir.appendingPathComponent("auxiliary.bin").path
        let machineIDPath = auxDir.appendingPathComponent("machineIdentifier.bin").path

        // Build the configuration.
        let hardware = HardwareProfile(
            cpuCoreCount: cpu,
            memorySize: memory * 1024 * 1024 // MiB -> bytes
        )

        // Validate hardware before proceeding.
        let hwIssues = hardware.validate()
        if !hwIssues.isEmpty {
            for issue in hwIssues {
                print("error: \(issue.description)")
            }
            throw ExitCode.validationFailure
        }

        let config = VMConfiguration(
            id: vmID,
            identity: VMIdentity(name: name, iconName: "desktopcomputer"),
            guestOS: .macOS,
            hardware: hardware,
            storage: StorageConfiguration(disks: [
                .bootDisk(imagePath: diskImagePath, sizeGiB: disk)
            ]),
            network: .singleNAT,
            display: .standard,
            audio: .systemDefaults,
            clipboard: .enabled,
            bootConfig: .macOS(
                auxiliaryStoragePath: auxStoragePath,
                machineIdentifierPath: machineIDPath
            )
        )

        // Persist the bundle (creates directory structure + config.json).
        try repository.save(config)

        // Create the sparse disk image.
        let diskSizeBytes = disk * 1024 * 1024 * 1024
        try fileManager.createDiskImage(
            at: URL(fileURLWithPath: diskImagePath),
            sizeInBytes: diskSizeBytes
        )

        // Print results.
        print("VM created successfully.")
        print("")
        print("  ID:     \(vmID.uuidString)")
        print("  Name:   \(name)")
        print("  CPU:    \(cpu) cores")
        print("  Memory: \(hardware.memoryDisplayString)")
        print("  Disk:   \(disk) GiB")
        print("  Bundle: \(bundlePath.path)")
        print("")
        print("Next step: install macOS into this VM:")
        print("  vortex install-macos --vm \(vmID.uuidString)")
    }
}
