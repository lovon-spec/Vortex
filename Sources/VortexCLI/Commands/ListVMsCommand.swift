// ListVMsCommand.swift — List all Vortex virtual machines.
// VortexCLI
//
// Reads all VM configurations from the persistence layer and displays
// them in a formatted table.
//
// Usage:
//   vortex list-vms

import ArgumentParser
import Foundation
import VortexCore
import VortexPersistence

struct ListVMsCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list-vms",
        abstract: "List all virtual machines.",
        discussion: """
            Lists all VM configurations stored in \
            ~/Library/Application Support/Vortex/VirtualMachines/. \
            Shows the VM ID, name, guest OS, hardware allocation, and \
            last-modified date for each VM.
            """
    )

    @Flag(
        name: .long,
        help: "Show detailed information for each VM."
    )
    var verbose: Bool = false

    // MARK: - Run

    func run() throws {
        let repository = VMRepository()
        let configs: [VMConfiguration]

        do {
            configs = try repository.loadAll()
        } catch {
            print("error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        if configs.isEmpty {
            print("No virtual machines found.")
            print("")
            print("Create one with:")
            print("  vortex create-vm --name \"My macOS VM\" --cpu 4 --memory 8192 --disk 64")
            return
        }

        print("Virtual Machines (\(configs.count)):")
        print("")

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for config in configs {
            print("  \(config.id.uuidString)")
            print("    Name:     \(config.identity.name)")
            print("    OS:       \(config.guestOS.displayName)")
            print("    CPU:      \(config.hardware.cpuCoreCount) cores")
            print("    Memory:   \(config.hardware.memoryDisplayString)")

            if let bootDisk = config.storage.bootDisk {
                print("    Disk:     \(bootDisk.sizeDisplayString)")
            }

            print("    Audio:    \(audioSummary(config.audio))")
            print("    Modified: \(dateFormatter.string(from: config.modifiedAt))")

            if verbose {
                print("    Network:  \(config.network.interfaces.count) interface(s)")
                print("    Bundle:   \(VMFileManager().vmBundlePath(for: config.id).path)")

                if let bootDisk = config.storage.bootDisk {
                    print("    Image:    \(bootDisk.imagePath)")
                }
            }

            print("")
        }
    }

    // MARK: - Helpers

    /// Summarizes the audio configuration for display.
    private func audioSummary(_ audio: AudioConfig) -> String {
        guard audio.enabled else { return "disabled" }

        var parts: [String] = []
        if let output = audio.output {
            parts.append("out=\(output.hostDeviceName)")
        }
        if let input = audio.input {
            parts.append("in=\(input.hostDeviceName)")
        }

        if parts.isEmpty {
            return "system defaults"
        }
        return parts.joined(separator: ", ")
    }
}
