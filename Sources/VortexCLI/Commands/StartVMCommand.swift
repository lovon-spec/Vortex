// StartVMCommand.swift — Start a macOS VM with vsock audio bridge.
// VortexCLI
//
// Loads a VM configuration from persistence, creates the VZ virtual machine
// (with no VZ audio -- audio is tunnelled over vsock), attaches the
// VsockAudioBridge for per-VM device routing, and keeps the process alive
// until the VM stops or the user presses Ctrl+C.
//
// Usage:
//   vortex start-vm --vm <uuid>
//   vortex start-vm --vm <uuid> --audio-output "BlackHole 16ch"
//   vortex start-vm --vm <uuid> --audio-output "BlackHole 16ch" --audio-input "BlackHole 2ch"

import ArgumentParser
import Foundation
import os
import Virtualization
import VortexAudio
import VortexCore
import VortexPersistence
import VortexVZ

struct StartVMCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "start-vm",
        abstract: "Start a macOS VM with vsock audio bridge.",
        discussion: """
            Starts a previously created and installed macOS VM. Audio is routed \
            through a vsock tunnel to the specified host audio devices, bypassing \
            VZ's locked-down audio path for per-VM device targeting.

            The process stays running until the VM stops or you press Ctrl+C.

            The guest must have the Vortex audio daemon installed and running \
            to establish the vsock audio connection.
            """
    )

    @Option(
        name: .long,
        help: "UUID of the VM to start."
    )
    var vm: String

    @Option(
        name: .long,
        help: "Host audio output device name for this VM (e.g. \"BlackHole 16ch\"). Uses system default if omitted."
    )
    var audioOutput: String?

    @Option(
        name: .long,
        help: "Host audio input device name for this VM (e.g. \"BlackHole 2ch\"). Input disabled if omitted."
    )
    var audioInput: String?

    @Flag(
        name: .long,
        help: "Disable audio entirely for this VM session."
    )
    var noAudio: Bool = false

    @Flag(
        name: [.long, .short],
        help: "Enable verbose logging. Streams os.Logger debug messages to stderr."
    )
    var verbose: Bool = false

    // MARK: - Run

    func run() throws {
        if verbose {
            // Enable debug-level messages for the com.vortex subsystem.
            // os.Logger debug messages are normally suppressed unless the
            // subsystem is configured for debug. Setting OS_ACTIVITY_MODE
            // and using `log stream` achieves this at the system level.
            // For the CLI, we set the environment hint and print guidance.
            setenv("OS_ACTIVITY_MODE", "debug", 1)
            VortexLog.cli.info("Verbose logging enabled (debug-level messages active)")
            print("Verbose mode: debug messages active.")
            print("  Tip: In another terminal, run:")
            print("    log stream --predicate 'subsystem == \"com.vortex\"' --level debug")
            print("")
        }

        guard let vmID = UUID(uuidString: vm) else {
            print("error: '\(vm)' is not a valid UUID.")
            throw ExitCode.validationFailure
        }

        let repository = VMRepository()

        // Load VM configuration.
        var config: VMConfiguration
        do {
            config = try repository.load(id: vmID)
        } catch {
            print("error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Starting VM '\(config.identity.name)' (\(vmID.uuidString))")
        print("  CPU:    \(config.hardware.cpuCoreCount) cores")
        print("  Memory: \(config.hardware.memoryDisplayString)")
        print("  OS:     \(config.guestOS.displayName)")
        print("")

        // Resolve audio device names to AudioEndpointConfig.
        let audioConfig: AudioConfig
        if noAudio {
            audioConfig = .disabled
            print("  Audio:  disabled")
        } else {
            let resolvedConfig = try resolveAudioConfig()
            audioConfig = resolvedConfig
        }

        // Override the persisted audio config with CLI-specified devices.
        config.audio = audioConfig
        print("")

        // Track state for RunLoop exit.
        var runError: Error?
        var finished = false

        // Install SIGINT (Ctrl+C) handler for graceful shutdown.
        let sigintSource = DispatchSource.makeSignalSource(
            signal: SIGINT, queue: .main
        )
        signal(SIGINT, SIG_IGN) // Let GCD handle it.

        Task { @MainActor in
            let manager = VZVMManager()
            var audioBridge: VsockAudioBridge?

            let vzVM: VZVirtualMachine
            do {
                vzVM = try manager.createVM(config: config)
            } catch {
                print("error: \(error.localizedDescription)")
                runError = ExitCode.failure
                finished = true
                CFRunLoopStop(CFRunLoopGetMain())
                return
            }

            // Graceful shutdown closure. Captures vzVM by value.
            func shutdown() {
                print("")
                print("Shutting down VM...")
                audioBridge?.detach()
                Task { @MainActor in
                    do {
                        try await manager.stop(vzVM)
                    } catch {
                        // Force stop if graceful fails.
                        try? await manager.forceStop(vzVM)
                    }
                }
            }

            // Wire up Ctrl+C.
            sigintSource.setEventHandler {
                shutdown()
            }
            sigintSource.resume()

            // Set up the state observer for VM lifecycle events.
            if let observer = manager.stateObserver(for: vzVM) {
                observer.onStateChange = { state in
                    switch state {
                    case .stopped:
                        print("")
                        print("VM stopped.")
                        audioBridge?.detach()
                        finished = true
                        CFRunLoopStop(CFRunLoopGetMain())
                    case .error:
                        print("")
                        print("VM encountered an error.")
                        audioBridge?.detach()
                        finished = true
                        CFRunLoopStop(CFRunLoopGetMain())
                    default:
                        break
                    }
                }

                observer.onError = { error in
                    print("VM error: \(error.localizedDescription)")
                    runError = ExitCode.failure
                }
            }

            // Start the VM.
            do {
                try await manager.start(vzVM)
                print("VM is running.")
            } catch {
                print("error: \(error.localizedDescription)")
                runError = ExitCode.failure
                finished = true
                CFRunLoopStop(CFRunLoopGetMain())
                return
            }

            // Attach the vsock audio bridge if audio is enabled.
            if config.audio.enabled {
                let bridge = VsockAudioBridge(vmID: vmID)
                audioBridge = bridge

                do {
                    try bridge.attach(to: vzVM, audioConfig: config.audio)
                    print("Vsock audio bridge listening on port \(VsockAudioBridge.audioPort).")
                    print("Waiting for guest audio daemon to connect...")
                } catch {
                    print("warning: Failed to attach audio bridge: \(error.localizedDescription)")
                    print("         VM will run without audio.")
                }
            }

            print("")
            print("Press Ctrl+C to stop the VM.")
        }

        // Run the main RunLoop. VZ requires the main RunLoop to be active
        // for the VM to operate. This blocks until the VM stops or Ctrl+C.
        while !finished {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }

        sigintSource.cancel()

        if let error = runError {
            throw error
        }
    }

    // MARK: - Audio Resolution

    /// Resolves CLI audio device name arguments into an AudioConfig.
    ///
    /// Enumerates host audio devices and matches by name. Prints the
    /// resolved device details for confirmation.
    private func resolveAudioConfig() throws -> AudioConfig {
        // If no audio arguments specified, use system defaults.
        guard audioOutput != nil || audioInput != nil else {
            print("  Audio:  system defaults")
            return .systemDefaults
        }

        let enumerator = AudioDeviceEnumerator()
        let allDevices: [AudioHostDevice]
        do {
            allDevices = try enumerator.allDevices()
        } catch {
            print("warning: Failed to enumerate audio devices: \(error)")
            print("         Falling back to system defaults.")
            return .systemDefaults
        }

        var outputEndpoint: AudioEndpointConfig?
        var inputEndpoint: AudioEndpointConfig?

        // Resolve output device.
        if let outputName = audioOutput {
            guard let device = allDevices.first(where: {
                $0.name == outputName && $0.isOutput
            }) else {
                print("error: Output device '\(outputName)' not found.")
                print("")
                print("Available output devices:")
                for dev in allDevices.where(\.isOutput) {
                    print("  - \"\(dev.name)\" (uid=\(dev.uid))")
                }
                throw ExitCode.validationFailure
            }
            outputEndpoint = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
            print("  Audio output: \(device.name) (uid=\(device.uid))")
        }

        // Resolve input device.
        if let inputName = audioInput {
            guard let device = allDevices.first(where: {
                $0.name == inputName && $0.isInput
            }) else {
                print("error: Input device '\(inputName)' not found.")
                print("")
                print("Available input devices:")
                for dev in allDevices.where(\.isInput) {
                    print("  - \"\(dev.name)\" (uid=\(dev.uid))")
                }
                throw ExitCode.validationFailure
            }
            inputEndpoint = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
            print("  Audio input:  \(device.name) (uid=\(device.uid))")
        }

        return AudioConfig(
            enabled: true,
            output: outputEndpoint,
            input: inputEndpoint
        )
    }
}

// MARK: - Sequence filter helper

private extension Array {
    /// Returns elements matching a boolean key path.
    func `where`(_ keyPath: KeyPath<Element, Bool>) -> [Element] {
        filter { $0[keyPath: keyPath] }
    }
}
