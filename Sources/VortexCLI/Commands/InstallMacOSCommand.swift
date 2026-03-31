// InstallMacOSCommand.swift — Install macOS into a VM from an IPSW.
// VortexCLI
//
// Downloads (or uses a local) IPSW restore image and runs the macOS
// installer via VZVMManager. This is a long-running operation (30+ min).
//
// Usage:
//   vortex install-macos --vm <uuid>
//   vortex install-macos --vm <uuid> --ipsw /path/to/restore.ipsw

import ArgumentParser
import Foundation
import VortexCore
import VortexPersistence
import VortexVZ

struct InstallMacOSCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "install-macos",
        abstract: "Install macOS into a virtual machine from an IPSW.",
        discussion: """
            Installs macOS into a previously created VM. If no IPSW path is \
            provided, the latest compatible macOS restore image is downloaded \
            from Apple automatically.

            This is a long-running operation that typically takes 30+ minutes \
            depending on download speed and hardware.
            """
    )

    @Option(
        name: .long,
        help: "UUID of the VM to install into (from 'vortex create-vm' output)."
    )
    var vm: String

    @Option(
        name: .long,
        help: "Path to a local macOS IPSW restore image. If omitted, downloads the latest."
    )
    var ipsw: String?

    // MARK: - Run

    // We cannot use AsyncParsableCommand here because VZVMManager is @MainActor
    // and we need the main RunLoop to be running for Virtualization.framework.
    // Instead, we set up the main RunLoop manually.
    func run() throws {
        guard let vmID = UUID(uuidString: vm) else {
            print("error: '\(vm)' is not a valid UUID.")
            throw ExitCode.validationFailure
        }

        let repository = VMRepository()

        // Load the VM configuration.
        let config: VMConfiguration
        do {
            config = try repository.load(id: vmID)
        } catch {
            print("error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard config.guestOS == .macOS else {
            print("error: VM '\(config.identity.name)' is not a macOS guest.")
            throw ExitCode.validationFailure
        }

        print("Installing macOS into VM '\(config.identity.name)' (\(vmID.uuidString))")
        print("")

        // Track completion so we can exit the RunLoop.
        var installError: Error?
        var finished = false

        Task { @MainActor in
            do {
                let manager = VZVMManager()

                // Resolve or download the IPSW.
                let ipswURL: URL
                if let ipswPath = self.ipsw {
                    ipswURL = URL(fileURLWithPath: ipswPath)
                    guard FileManager.default.fileExists(atPath: ipswPath) else {
                        print("error: IPSW file not found at '\(ipswPath)'.")
                        installError = ExitCode.failure
                        finished = true
                        return
                    }
                    print("Using local IPSW: \(ipswPath)")
                } else {
                    print("Downloading latest macOS restore image from Apple...")
                    print("(This may take a while depending on your connection speed.)")
                    print("")

                    let downloadDir = FileManager.default.urls(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask
                    ).first!
                        .appendingPathComponent("Vortex", isDirectory: true)
                        .appendingPathComponent("Downloads", isDirectory: true)

                    var lastPercent = -1
                    ipswURL = try await manager.downloadLatestRestore(
                        to: downloadDir
                    ) { fraction in
                        let percent = Int(fraction * 100)
                        if percent != lastPercent {
                            lastPercent = percent
                            Self.printProgress(
                                label: "Download",
                                percent: percent
                            )
                        }
                    }
                    print("") // Newline after progress bar.
                    print("Downloaded: \(ipswURL.lastPathComponent)")
                }

                print("")
                print("Starting macOS installation...")
                print("(This typically takes 30+ minutes. Do not interrupt.)")
                print("")

                var lastPercent = -1
                try await manager.installMacOS(
                    ipsw: ipswURL,
                    config: config
                ) { fraction in
                    let percent = Int(fraction * 100)
                    if percent != lastPercent {
                        lastPercent = percent
                        Self.printProgress(
                            label: "Install",
                            percent: percent
                        )
                    }
                }
                print("") // Newline after progress bar.
                print("")
                print("macOS installation completed successfully.")
                print("")
                print("Start the VM with:")
                print("  vortex start-vm --vm \(vmID.uuidString)")

            } catch {
                installError = error
            }

            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }

        // Run the main RunLoop until the install completes. VZ operations
        // require the main RunLoop to be active.
        while !finished {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }

        if let error = installError {
            if error is ExitCode {
                throw error
            }
            print("error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    // MARK: - Progress Display

    /// Prints a terminal progress bar that overwrites the current line.
    static func printProgress(label: String, percent: Int) {
        let barWidth = 40
        let filled = barWidth * percent / 100
        let empty = barWidth - filled
        let bar = String(repeating: "#", count: filled)
            + String(repeating: "-", count: empty)
        print("\r  \(label): [\(bar)] \(percent)%", terminator: "")
        fflush(stdout)
    }
}
