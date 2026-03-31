// VZConfigBuilder.swift — Minimal VZ configuration for Track A audio testing.
// VortexInterception
//
// Builds the lightest possible VZVirtualMachineConfiguration that includes
// VZVirtioSoundDeviceConfiguration. Used by the Track A validation test to
// determine whether VZ's audio path creates AudioUnit instances in-process.
//
// This is NOT a production configuration builder. It exists solely to provoke
// VZ's audio initialization code path so that AudioInterceptor hooks can
// observe whether AudioComponentInstanceNew is called in our process.

import Foundation
@preconcurrency import Virtualization
import os

/// Utilities for building minimal VZ configurations for Track A audio testing.
public enum VZConfigBuilder {

    private static let logger = Logger(
        subsystem: "com.vortex.interception",
        category: "VZConfigBuilder"
    )

    // MARK: - Minimal config (no VM start)

    /// Builds a minimal VZ configuration with audio devices and validates it.
    ///
    /// This does NOT create a `VZVirtualMachine` or attempt to start anything.
    /// It constructs a `VZVirtualMachineConfiguration` with
    /// `VZVirtioSoundDeviceConfiguration`, which may trigger AudioUnit creation
    /// during validation or setup.
    ///
    /// - Returns: A description of the configuration that was created.
    /// - Throws: If VZ rejects the configuration during validation.
    public static func buildMinimalAudioConfig() throws -> String {
        let config = VZVirtualMachineConfiguration()

        // Minimal resources — we are not trying to boot anything.
        config.cpuCount = 2
        config.memorySize = 2 * 1024 * 1024 * 1024 // 2 GiB

        // Generic platform + EFI boot (lightest config that VZ accepts).
        config.platform = VZGenericPlatformConfiguration()
        let bootLoader = VZEFIBootLoader()
        // No EFI variable store — this is intentional; we may not be able to
        // validate(), but we want to see if audio init happens during config setup.
        config.bootLoader = bootLoader

        // Entropy (required by VZ for a valid config).
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon (VZ often requires this).
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // -- THE KEY PART: Audio with VZVirtioSoundDeviceConfiguration --
        let sound = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        sound.streams = [outputStream]
        config.audioDevices = [sound]

        // Keyboard + pointing device (VZ may require these).
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        logger.info("Built minimal VZ config with audio devices")

        // Attempt validation. This may fail (no disk, no valid EFI store) but
        // the audio config itself is valid.
        do {
            try config.validate()
            return "Configuration validated successfully (with audio devices)."
        } catch {
            logger.info("VZ validation failed (expected): \(error.localizedDescription)")
            return "Configuration created but validation failed (expected: \(error.localizedDescription)). Audio devices were still configured."
        }
    }

    // MARK: - Attempt VM start (best-effort)

    /// Creates a scratch disk, builds a VZ config with audio, and attempts to
    /// start the VM. The VM will fail to boot (no OS installed), but VZ may
    /// initialize its audio subsystem during the start sequence.
    ///
    /// This method blocks the calling thread for up to `timeout` seconds.
    ///
    /// - Parameters:
    ///   - scratchDiskPath: Path to a scratch disk image. Created if it does not exist.
    ///   - timeout: Maximum seconds to wait for VM start.
    /// - Throws: Various errors from VZ or disk creation.
    public static func attemptVMStart(
        scratchDiskPath: String,
        timeout: Double
    ) throws {
        // Create scratch disk image if needed.
        let scratchURL = URL(fileURLWithPath: scratchDiskPath)
        if !FileManager.default.fileExists(atPath: scratchDiskPath) {
            logger.info("Creating scratch disk at \(scratchDiskPath)")
            let diskSize: UInt64 = 1 * 1024 * 1024 * 1024 // 1 GiB
            try createEmptyDiskImage(at: scratchURL, size: diskSize)
        }

        // Create a temporary EFI variable store.
        let efiStorePath = scratchDiskPath + ".efivars"
        let efiStoreURL = URL(fileURLWithPath: efiStorePath)
        if !FileManager.default.fileExists(atPath: efiStorePath) {
            logger.info("Creating EFI variable store at \(efiStorePath)")
            _ = try VZEFIVariableStore(creatingVariableStoreAt: efiStoreURL)
        }

        // Build config.
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 2
        config.memorySize = 2 * 1024 * 1024 * 1024

        config.platform = VZGenericPlatformConfiguration()
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: efiStoreURL)
        config.bootLoader = bootLoader

        // Storage.
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: scratchURL,
            readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Network (NAT, so VZ does not complain).
        let netDevice = VZVirtioNetworkDeviceConfiguration()
        netDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [netDevice]

        // Graphics.
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)
        ]
        config.graphicsDevices = [graphics]

        // Entropy + balloon.
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Input.
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // -- Audio --
        let sound = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        sound.streams = [outputStream]
        config.audioDevices = [sound]

        try config.validate()
        logger.info("Full VZ config validated — attempting VM start")

        // VZVirtualMachine must be accessed from a serial queue.
        let vmQueue = DispatchQueue(label: "com.vortex.tracka-test")
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        // VZ types are not Sendable but are safe to use on the VZ serial queue.
        // nonisolated(unsafe) suppresses the capture warning.
        nonisolated(unsafe) let vzConfig = config
        vmQueue.async {
            let vm = VZVirtualMachine(configuration: vzConfig, queue: vmQueue)
            nonisolated(unsafe) let vzVM = vm
            vm.start { result in
                switch result {
                case .success:
                    logger.info("VM started (unexpected for a blank disk)")
                    // Give it a moment for audio to initialize, then request stop.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                        vmQueue.async {
                            try? vzVM.requestStop()
                            semaphore.signal()
                        }
                    }
                case .failure(let error):
                    logger.info("VM start failed (expected): \(error.localizedDescription)")
                    startError = error
                    semaphore.signal()
                }
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)

        if waitResult == .timedOut {
            logger.info("VM start timed out after \(timeout)s")
            throw VMStartTestError.timeout
        }

        if let error = startError {
            throw error
        }
    }

    // MARK: - Private helpers

    private static func createEmptyDiskImage(at url: URL, size: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw VMStartTestError.diskCreationFailed(
                "Could not create file at \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
    }
}

// MARK: - VMStartTestError

/// Errors specific to the Track A VM start test.
enum VMStartTestError: Error, CustomStringConvertible {
    case timeout
    case diskCreationFailed(String)

    var description: String {
        switch self {
        case .timeout:
            return "VM start timed out"
        case .diskCreationFailed(let reason):
            return "Failed to create scratch disk: \(reason)"
        }
    }
}
