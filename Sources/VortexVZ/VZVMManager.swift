// VZVMManager.swift — Virtualization.framework macOS VM lifecycle manager.
// VortexVZ
//
// Creates and manages macOS guest VMs using Apple's Virtualization.framework.
// Audio is explicitly NOT configured here — audio is tunnelled over vsock
// via VsockAudioBridge to bypass VZ's locked-down audio path.

import Foundation
import Virtualization
import VortexCore
import VortexPersistence

// MARK: - VZVMManager

/// Manages the lifecycle of macOS (and Linux) guest VMs using
/// Virtualization.framework.
///
/// This class translates a `VMConfiguration` model into the corresponding
/// `VZVirtualMachineConfiguration`, handles IPSW installation, and provides
/// start/stop/pause/resume controls.
///
/// **Audio policy:** `VZVirtioSoundDeviceConfiguration` is intentionally
/// omitted. All audio is routed through a `VZVirtioSocketDevice` and handled
/// by `VsockAudioBridge`, giving us per-VM device targeting that VZ cannot
/// provide natively.
///
/// **Threading model:** All VZ operations must run on the main actor.
/// Long-running operations (install, download) use async/await and report
/// progress via a callback.
@MainActor
public final class VZVMManager: NSObject {

    // MARK: - Properties

    /// File manager for resolving VM bundle paths.
    private let fileManager: VMFileManager

    /// Tracks the most recent delegate-reported state per VM.
    /// Keyed by the ObjectIdentifier of the VZVirtualMachine.
    private var stateObservers: [ObjectIdentifier: VZVMStateObserver] = [:]

    // MARK: - Init

    /// Creates a manager with the given persistence layer.
    ///
    /// - Parameter fileManager: The VM file manager used to resolve bundle
    ///   paths for disk images and auxiliary storage. Defaults to the standard
    ///   Application Support location.
    public init(fileManager: VMFileManager = VMFileManager()) {
        self.fileManager = fileManager
        super.init()
    }

    // MARK: - VM Creation

    /// Creates a `VZVirtualMachine` from a `VMConfiguration`.
    ///
    /// The returned machine is fully configured but not started. Call
    /// `start(_:)` to begin execution.
    ///
    /// - Parameter config: The Vortex VM configuration to translate.
    /// - Returns: A configured `VZVirtualMachine` ready for `start()`.
    /// - Throws: `VortexError` if the configuration is invalid or VZ
    ///   rejects it.
    public func createVM(config: VMConfiguration) throws -> VZVirtualMachine {
        let issues = config.validate()
        if !issues.isEmpty {
            throw VortexError.invalidConfiguration(issues: issues)
        }

        let vzConfig = try buildVZConfiguration(from: config)

        do {
            try vzConfig.validate()
        } catch {
            throw VortexError.vmCreationFailed(
                reason: "VZ configuration validation failed: \(error.localizedDescription)"
            )
        }

        let vm = VZVirtualMachine(configuration: vzConfig)

        // Install a delegate to track state changes.
        let observer = VZVMStateObserver(vmID: config.id)
        stateObservers[ObjectIdentifier(vm)] = observer
        vm.delegate = observer

        return vm
    }

    // MARK: - macOS Installation

    /// Installs macOS from an IPSW restore image into a VM.
    ///
    /// This performs a full macOS installation into the VM's disk image.
    /// The VM configuration must target macOS with a valid boot disk and
    /// auxiliary storage path.
    ///
    /// - Parameters:
    ///   - ipsw: URL to the macOS IPSW restore image file.
    ///   - config: The VM configuration (must be macOS guest type).
    ///   - progress: Called periodically with a value in 0.0...1.0
    ///     indicating installation progress.
    /// - Throws: `VortexError` if the IPSW is invalid, the configuration
    ///   is wrong, or installation fails.
    public func installMacOS(
        ipsw: URL,
        config: VMConfiguration,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard config.guestOS == .macOS else {
            throw VortexError.vmCreationFailed(
                reason: "macOS installation requires a macOS guest configuration."
            )
        }

        guard config.bootConfig.mode == .macOS else {
            throw VortexError.vmCreationFailed(
                reason: "macOS installation requires macOS boot mode."
            )
        }

        // Load the restore image to get the hardware model for compatibility check.
        let restoreImage = try await loadRestoreImage(from: ipsw)

        guard let mostFeaturefulRequirements = restoreImage
            .mostFeaturefulSupportedConfiguration else {
            throw VortexError.vmCreationFailed(
                reason: "No supported configuration found in the restore image. "
                    + "This IPSW may not be compatible with this host."
            )
        }

        let hardwareModel = mostFeaturefulRequirements.hardwareModel

        // Create auxiliary storage (NVRAM) if it doesn't exist.
        guard let auxPath = config.bootConfig.auxiliaryStoragePath else {
            throw VortexError.vmCreationFailed(
                reason: "macOS boot config is missing auxiliaryStoragePath."
            )
        }

        let auxURL = URL(fileURLWithPath: auxPath)
        let auxStorage: VZMacAuxiliaryStorage
        if FileManager.default.fileExists(atPath: auxPath) {
            auxStorage = VZMacAuxiliaryStorage(contentsOf: auxURL)
        } else {
            auxStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxURL,
                hardwareModel: hardwareModel
            )
        }

        // Create and save the machine identifier if it doesn't exist.
        guard let machineIDPath = config.bootConfig.machineIdentifierPath else {
            throw VortexError.vmCreationFailed(
                reason: "macOS boot config is missing machineIdentifierPath."
            )
        }

        let machineIDURL = URL(fileURLWithPath: machineIDPath)
        let machineIdentifier: VZMacMachineIdentifier
        if FileManager.default.fileExists(atPath: machineIDPath) {
            guard let idData = try? Data(contentsOf: machineIDURL),
                  let existingID = VZMacMachineIdentifier(dataRepresentation: idData) else {
                throw VortexError.vmCreationFailed(
                    reason: "Failed to load existing machine identifier from \(machineIDPath)."
                )
            }
            machineIdentifier = existingID
        } else {
            machineIdentifier = VZMacMachineIdentifier()
            let parentDir = machineIDURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true
            )
            try machineIdentifier.dataRepresentation.write(to: machineIDURL)
        }

        // Build a VZ config using the hardware model from the restore image.
        // We need to create an actual VZ configuration for the installer.
        let vzConfig = try buildVZConfiguration(
            from: config,
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
            auxiliaryStorage: auxStorage
        )
        try vzConfig.validate()

        let vm = VZVirtualMachine(configuration: vzConfig)

        // Run the installer.
        let installer = VZMacOSInstaller(
            virtualMachine: vm,
            restoringFromImageAt: ipsw
        )

        // Observe progress via KVO.
        let progressObservation = installer.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { observedProgress, _ in
            progress(observedProgress.fractionCompleted)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            installer.install { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(
                        throwing: VortexError.bootFailed(
                            reason: "macOS installation failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }

        // Clean up KVO observation.
        progressObservation.invalidate()

        // Save the hardware model for future boots.
        let hardwareModelURL: URL = {
            if let explicitPath = config.bootConfig.hardwareModelPath {
                return URL(fileURLWithPath: explicitPath)
            }
            return URL(fileURLWithPath: auxPath)
                .deletingLastPathComponent()
                .appendingPathComponent("hardwareModel.bin")
        }()
        let hardwareModelParent = hardwareModelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: hardwareModelParent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try hardwareModel.dataRepresentation.write(to: hardwareModelURL)
    }

    // MARK: - Restore Image Download

    /// Downloads the latest macOS restore image from Apple.
    ///
    /// - Parameters:
    ///   - destination: The directory URL where the IPSW should be saved.
    ///   - progress: Called periodically with download progress (0.0...1.0).
    /// - Returns: The URL of the downloaded IPSW file.
    /// - Throws: `VortexError` if the download fails or no image is available.
    public func downloadLatestRestore(
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let image = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<VZMacOSRestoreImage, Error>) in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: image)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        let downloadURL = image.url

        // Download with URLSession for progress tracking.
        let session = URLSession.shared
        let destinationFile = destination.appendingPathComponent(
            downloadURL.lastPathComponent
        )

        let (tempURL, _) = try await session.download(from: downloadURL) { totalBytesWritten, totalBytesExpectedToWrite in
            if totalBytesExpectedToWrite > 0 {
                let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                progress(fraction)
            }
        }

        // Move from temp location to final destination.
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationFile.path) {
            try FileManager.default.removeItem(at: destinationFile)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationFile)

        return destinationFile
    }

    // MARK: - VM Lifecycle

    /// Starts a stopped VM.
    ///
    /// - Parameter vm: The virtual machine to start. Must be in the stopped state.
    /// - Throws: `VortexError.vmStartFailed` if the VM fails to start.
    public func start(_ vm: VZVirtualMachine) async throws {
        guard vm.canStart else {
            throw VortexError.vmStartFailed(
                reason: "VM is not in a startable state (current: \(vm.state.displayName))."
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(
                        throwing: VortexError.vmStartFailed(
                            reason: error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    /// Requests the VM to stop gracefully.
    ///
    /// Sends an ACPI shutdown request to the guest. The guest OS should
    /// handle this as a power-off event and shut down cleanly.
    ///
    /// - Parameter vm: The virtual machine to stop.
    /// - Throws: `VortexError.vmStopTimeout` or `VortexError.internalError`
    ///   if the request fails.
    public func stop(_ vm: VZVirtualMachine) async throws {
        guard vm.canRequestStop else {
            // Fall back to force stop if graceful is not available.
            try await forceStop(vm)
            return
        }

        do {
            try vm.requestStop()
        } catch {
            throw VortexError.internalError(
                reason: "Failed to request VM stop: \(error.localizedDescription)"
            )
        }
    }

    /// Immediately terminates the VM without waiting for guest cooperation.
    ///
    /// - Parameter vm: The virtual machine to force-stop.
    /// - Throws: `VortexError.internalError` if the operation fails.
    public func forceStop(_ vm: VZVirtualMachine) async throws {
        guard vm.canStop else {
            throw VortexError.internalError(
                reason: "VM is not in a stoppable state (current: \(vm.state.displayName))."
            )
        }

        try await vm.stop()
    }

    /// Pauses VM execution, freezing all vCPUs.
    ///
    /// - Parameter vm: The virtual machine to pause. Must be running.
    /// - Throws: `VortexError.internalError` if pause fails.
    public func pause(_ vm: VZVirtualMachine) async throws {
        guard vm.canPause else {
            throw VortexError.internalError(
                reason: "VM is not in a pausable state (current: \(vm.state.displayName))."
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.pause { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(
                        throwing: VortexError.internalError(
                            reason: "Failed to pause VM: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    /// Resumes a paused VM.
    ///
    /// - Parameter vm: The virtual machine to resume. Must be paused.
    /// - Throws: `VortexError.internalError` if resume fails.
    public func resume(_ vm: VZVirtualMachine) async throws {
        guard vm.canResume else {
            throw VortexError.internalError(
                reason: "VM is not in a resumable state (current: \(vm.state.displayName))."
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.resume { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(
                        throwing: VortexError.internalError(
                            reason: "Failed to resume VM: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    // MARK: - Vsock Device Access

    /// Returns the first `VZVirtioSocketDevice` attached to the VM, if any.
    ///
    /// Used by `VsockAudioBridge` to set up the audio tunnel listener.
    ///
    /// - Parameter vm: The virtual machine to query.
    /// - Returns: The socket device, or `nil` if none is configured.
    public func vsockDevice(for vm: VZVirtualMachine) -> VZVirtioSocketDevice? {
        vm.socketDevices.first as? VZVirtioSocketDevice
    }

    // MARK: - State Observer Access

    /// Returns the state observer for a given VM, if one exists.
    ///
    /// - Parameter vm: The virtual machine.
    /// - Returns: The observer tracking this VM's state, or `nil`.
    public func stateObserver(for vm: VZVirtualMachine) -> VZVMStateObserver? {
        stateObservers[ObjectIdentifier(vm)]
    }

    /// Removes the state observer for a given VM.
    ///
    /// Call this when the VM is fully torn down to avoid retaining the observer.
    ///
    /// - Parameter vm: The virtual machine to remove tracking for.
    public func removeStateObserver(for vm: VZVirtualMachine) {
        stateObservers.removeValue(forKey: ObjectIdentifier(vm))
    }

    // MARK: - Private: Configuration Building

    /// Builds a complete `VZVirtualMachineConfiguration` from a `VMConfiguration`.
    ///
    /// - Parameters:
    ///   - config: The Vortex configuration model.
    ///   - hardwareModel: Override hardware model (used during installation).
    ///   - machineIdentifier: Override machine identifier (used during installation).
    ///   - auxiliaryStorage: Override auxiliary storage (used during installation).
    /// - Returns: A fully configured `VZVirtualMachineConfiguration`.
    private func buildVZConfiguration(
        from config: VMConfiguration,
        hardwareModel: VZMacHardwareModel? = nil,
        machineIdentifier: VZMacMachineIdentifier? = nil,
        auxiliaryStorage: VZMacAuxiliaryStorage? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let vzConfig = VZVirtualMachineConfiguration()

        // -- CPU & Memory --
        vzConfig.cpuCount = config.hardware.cpuCoreCount
        vzConfig.memorySize = config.hardware.memorySize

        // -- Platform --
        switch config.guestOS {
        case .macOS:
            vzConfig.platform = try buildMacPlatform(
                config: config,
                hardwareModel: hardwareModel,
                machineIdentifier: machineIdentifier,
                auxiliaryStorage: auxiliaryStorage
            )
            vzConfig.bootLoader = VZMacOSBootLoader()

        case .linuxARM64, .windowsARM:
            let efiBootLoader = try buildEFIBootLoader(config: config)
            vzConfig.bootLoader = efiBootLoader
            vzConfig.platform = VZGenericPlatformConfiguration()
        }

        // -- Storage --
        vzConfig.storageDevices = try buildStorageDevices(config: config)

        // -- Network --
        vzConfig.networkDevices = buildNetworkDevices(config: config)

        // -- Display --
        vzConfig.graphicsDevices = buildGraphicsDevices(config: config)

        // -- Audio: intentionally NOT configured. --
        // Audio is handled by the vsock bridge (VsockAudioBridge).
        // VZVirtioSoundDeviceConfiguration is NOT added here.

        // -- Vsock: required for audio transport. --
        let vsockConfig = VZVirtioSocketDeviceConfiguration()
        vzConfig.socketDevices = [vsockConfig]

        // -- Entropy --
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // -- Memory Balloon --
        vzConfig.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        // -- Keyboard & Pointing Device --
        if config.guestOS == .macOS {
            vzConfig.keyboards = [VZMacKeyboardConfiguration()]
            vzConfig.pointingDevices = [VZMacTrackpadConfiguration()]
        } else {
            vzConfig.keyboards = [VZUSBKeyboardConfiguration()]
            vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        // -- Shared Folders (VirtioFS) --
        vzConfig.directorySharingDevices = buildSharedFolders(config: config)

        // -- Clipboard (macOS only) --
        if config.guestOS == .macOS && config.clipboard.enabled {
            let spiceAgent = VZSpiceAgentPortAttachment()
            spiceAgent.sharesClipboard = true
            let consoleConfig = VZVirtioConsoleDeviceConfiguration()
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            port.attachment = spiceAgent
            consoleConfig.ports[0] = port
            vzConfig.consoleDevices = [consoleConfig]
        }

        // -- Rosetta (Linux ARM64 only) --
        if let rosetta = config.rosetta, rosetta.enabled, config.guestOS == .linuxARM64 {
            if VZLinuxRosettaDirectoryShare.availability == .installed {
                let rosettaShare = try VZLinuxRosettaDirectoryShare()
                let rosettaFS = VZVirtioFileSystemDeviceConfiguration(tag: rosetta.mountTag)
                rosettaFS.share = rosettaShare
                vzConfig.directorySharingDevices.append(rosettaFS)
            }
        }

        return vzConfig
    }

    /// Builds the macOS platform configuration.
    private func buildMacPlatform(
        config: VMConfiguration,
        hardwareModel: VZMacHardwareModel?,
        machineIdentifier: VZMacMachineIdentifier?,
        auxiliaryStorage: VZMacAuxiliaryStorage?
    ) throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()

        // Hardware model: prefer override, then load from disk.
        if let model = hardwareModel {
            platform.hardwareModel = model
        } else {
            let hwModelURL: URL
            if let explicitPath = config.bootConfig.hardwareModelPath {
                hwModelURL = URL(fileURLWithPath: explicitPath)
            } else {
                guard let auxPath = config.bootConfig.auxiliaryStoragePath else {
                    throw VortexError.vmCreationFailed(
                        reason: "macOS platform requires auxiliaryStoragePath."
                    )
                }
                hwModelURL = URL(fileURLWithPath: auxPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("hardwareModel.bin")
            }
            guard let hwData = try? Data(contentsOf: hwModelURL),
                  let model = VZMacHardwareModel(dataRepresentation: hwData) else {
                throw VortexError.vmCreationFailed(
                    reason: "Failed to load hardware model from \(hwModelURL.path). "
                        + "Run macOS installation first."
                )
            }
            guard model.isSupported else {
                throw VortexError.vmCreationFailed(
                    reason: "Hardware model is not supported on this host."
                )
            }
            platform.hardwareModel = model
        }

        // Machine identifier: prefer override, then load from disk.
        if let identifier = machineIdentifier {
            platform.machineIdentifier = identifier
        } else {
            guard let machineIDPath = config.bootConfig.machineIdentifierPath else {
                throw VortexError.vmCreationFailed(
                    reason: "macOS platform requires machineIdentifierPath."
                )
            }
            let machineIDURL = URL(fileURLWithPath: machineIDPath)
            guard let idData = try? Data(contentsOf: machineIDURL),
                  let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
                throw VortexError.vmCreationFailed(
                    reason: "Failed to load machine identifier from \(machineIDPath)."
                )
            }
            platform.machineIdentifier = identifier
        }

        // Auxiliary storage (NVRAM): prefer override, then load from disk.
        if let storage = auxiliaryStorage {
            platform.auxiliaryStorage = storage
        } else {
            guard let auxPath = config.bootConfig.auxiliaryStoragePath else {
                throw VortexError.vmCreationFailed(
                    reason: "macOS platform requires auxiliaryStoragePath."
                )
            }
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(
                contentsOf: URL(fileURLWithPath: auxPath)
            )
        }

        return platform
    }

    /// Builds the EFI boot loader for Linux/Windows guests.
    private func buildEFIBootLoader(
        config: VMConfiguration
    ) throws -> VZEFIBootLoader {
        guard let efiStorePath = config.bootConfig.uefiStorePath else {
            throw VortexError.vmCreationFailed(
                reason: "UEFI boot mode requires uefiStorePath."
            )
        }

        let efiStoreURL = URL(fileURLWithPath: efiStorePath)
        let variableStore: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: efiStorePath) {
            variableStore = VZEFIVariableStore(url: efiStoreURL)
        } else {
            let parentDir = efiStoreURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true
            )
            variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: efiStoreURL
            )
        }

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = variableStore
        return bootLoader
    }

    /// Builds disk storage attachments from the storage configuration.
    private func buildStorageDevices(
        config: VMConfiguration
    ) throws -> [VZStorageDeviceConfiguration] {
        var devices: [VZStorageDeviceConfiguration] = []

        for disk in config.storage.disks {
            let imageURL = URL(fileURLWithPath: disk.imagePath)

            guard FileManager.default.fileExists(atPath: disk.imagePath) else {
                throw VortexError.fileNotFound(path: disk.imagePath)
            }

            let attachment: VZDiskImageStorageDeviceAttachment
            do {
                let cachingMode: VZDiskImageCachingMode = {
                    switch disk.cachingMode {
                    case .automatic: return .automatic
                    case .writeBack: return .automatic
                    case .writeThrough: return .automatic
                    case .none: return .automatic
                    }
                }()

                let syncMode: VZDiskImageSynchronizationMode = {
                    switch disk.syncMode {
                    case .full: return .full
                    case .unsafe: return .none
                    }
                }()

                attachment = try VZDiskImageStorageDeviceAttachment(
                    url: imageURL,
                    readOnly: disk.readOnly,
                    cachingMode: cachingMode,
                    synchronizationMode: syncMode
                )
            } catch {
                throw VortexError.diskOperationFailed(
                    reason: "Failed to attach disk '\(disk.label)' at \(disk.imagePath): "
                        + "\(error.localizedDescription)"
                )
            }

            switch disk.deviceType {
            case .virtioBlock:
                let blockDevice = VZVirtioBlockDeviceConfiguration(
                    attachment: attachment
                )
                devices.append(blockDevice)

            case .usbMassStorage:
                let usbDevice = VZUSBMassStorageDeviceConfiguration(
                    attachment: attachment
                )
                devices.append(usbDevice)
            }
        }

        return devices
    }

    /// Builds network device configurations from the network configuration.
    private func buildNetworkDevices(
        config: VMConfiguration
    ) -> [VZNetworkDeviceConfiguration] {
        var devices: [VZNetworkDeviceConfiguration] = []

        for iface in config.network.interfaces {
            let netConfig = VZVirtioNetworkDeviceConfiguration()

            switch iface.mode {
            case .nat:
                netConfig.attachment = VZNATNetworkDeviceAttachment()

            case .bridged(let hostInterface):
                // Find the named host interface.
                if let bridgeIface = VZBridgedNetworkInterface.networkInterfaces
                    .first(where: { $0.identifier == hostInterface }) {
                    netConfig.attachment = VZBridgedNetworkDeviceAttachment(
                        interface: bridgeIface
                    )
                } else {
                    // Fall back to NAT if the named interface is not found.
                    netConfig.attachment = VZNATNetworkDeviceAttachment()
                }

            case .hostOnly:
                // VZ doesn't have a dedicated host-only mode.
                // Use NAT as the closest approximation; the firewall rules
                // can further restrict outbound traffic if needed.
                netConfig.attachment = VZNATNetworkDeviceAttachment()
            }

            // Set MAC address if specified.
            if let macString = iface.macAddress,
               let mac = VZMACAddress(string: macString) {
                netConfig.macAddress = mac
            }

            devices.append(netConfig)
        }

        return devices
    }

    /// Builds graphics device configurations for the display.
    private func buildGraphicsDevices(
        config: VMConfiguration
    ) -> [VZGraphicsDeviceConfiguration] {
        switch config.guestOS {
        case .macOS:
            let macGraphics = VZMacGraphicsDeviceConfiguration()
            macGraphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    widthInPixels: config.display.widthPixels,
                    heightInPixels: config.display.heightPixels,
                    pixelsPerInch: config.display.pixelsPerInch
                )
            ]
            return [macGraphics]

        case .linuxARM64, .windowsARM:
            let virtioGPU = VZVirtioGraphicsDeviceConfiguration()
            virtioGPU.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(
                    widthInPixels: config.display.widthPixels,
                    heightInPixels: config.display.heightPixels
                )
            ]
            return [virtioGPU]
        }
    }

    /// Builds VirtioFS shared folder configurations.
    private func buildSharedFolders(
        config: VMConfiguration
    ) -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []

        for folder in config.sharedFolders {
            let hostURL = URL(fileURLWithPath: folder.hostPath)
            guard FileManager.default.fileExists(atPath: folder.hostPath) else {
                // Skip non-existent shared folders rather than failing.
                continue
            }

            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: hostURL, readOnly: folder.readOnly)
            )
            let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: folder.tag)
            fsConfig.share = share
            devices.append(fsConfig)
        }

        return devices
    }

    // MARK: - Private: Restore Image Loading

    /// Loads a `VZMacOSRestoreImage` from a local IPSW file.
    private func loadRestoreImage(
        from url: URL
    ) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<VZMacOSRestoreImage, Error>) in
            VZMacOSRestoreImage.load(from: url) { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: image)
                case .failure(let error):
                    continuation.resume(
                        throwing: VortexError.invalidRestoreImage(
                            path: url.path,
                            reason: error.localizedDescription
                        )
                    )
                }
            }
        }
    }
}

// MARK: - VZVMStateObserver

/// Delegate object that tracks VZ virtual machine state changes.
///
/// Each VM gets its own observer. The observer converts VZ state changes
/// into `VMState` values and can notify listeners.
public final class VZVMStateObserver: NSObject, VZVirtualMachineDelegate {

    /// The Vortex VM ID associated with this observer.
    public let vmID: UUID

    /// The current state, updated by delegate callbacks.
    public private(set) var currentState: VMState = .stopped

    /// Callback invoked when the VM state changes.
    public var onStateChange: ((VMState) -> Void)?

    /// Callback invoked when the VM stops due to an error.
    public var onError: ((Error) -> Void)?

    public init(vmID: UUID) {
        self.vmID = vmID
        super.init()
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        currentState = .stopped
        onStateChange?(.stopped)
    }

    public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        currentState = .error
        onStateChange?(.error)
        onError?(error)
    }

    public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        // Network disconnects are not fatal — log but do not change state.
    }
}

// MARK: - VZVirtualMachine.State Extension

extension VZVirtualMachine.State {
    /// Human-readable name for VZ states (used in error messages).
    var displayName: String {
        switch self {
        case .stopped:  return "stopped"
        case .running:  return "running"
        case .paused:   return "paused"
        case .error:    return "error"
        case .starting: return "starting"
        case .stopping: return "stopping"
        case .resuming: return "resuming"
        case .pausing:  return "pausing"
        case .saving:   return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - URLSession Extension (progress download)

extension URLSession {
    /// Downloads a file from a URL with progress reporting.
    ///
    /// This is a simple wrapper that uses a `URLSessionDownloadTask` with
    /// a delegate to report progress.
    fileprivate func download(
        from url: URL,
        progressHandler: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            let delegate = DownloadProgressDelegate(
                progressHandler: progressHandler,
                completion: continuation
            )
            let task = self.downloadTask(with: url)
            // Store the delegate to keep it alive for the duration.
            objc_setAssociatedObject(
                task, "vortex_delegate", delegate,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            task.delegate = delegate
            task.resume()
        }
    }
}

/// URLSession download delegate that reports progress and completes via
/// a checked continuation.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Int64, Int64) -> Void
    let completion: CheckedContinuation<(URL, URLResponse), Error>

    init(
        progressHandler: @escaping (Int64, Int64) -> Void,
        completion: CheckedContinuation<(URL, URLResponse), Error>
    ) {
        self.progressHandler = progressHandler
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response else {
            completion.resume(
                throwing: VortexError.bootFailed(
                    reason: "Download completed without a response."
                )
            )
            return
        }
        completion.resume(returning: (location, response))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            completion.resume(
                throwing: VortexError.bootFailed(
                    reason: "Download failed: \(error.localizedDescription)"
                )
            )
        }
    }
}
