// VZVMManager.swift — Track A: VZ macOS VM with audio interception.
// VortexInterception
//
// This is the Track A variant of VM management. Unlike VortexVZ (which omits
// VZ audio and tunnels over vsock), this version ENABLES VZ's native
// VZVirtioSoundDeviceConfiguration and relies on AudioInterceptor to redirect
// the resulting AudioUnit instances to the desired host device.
//
// The existing VortexVZ.VZVMManager is the production path. This module exists
// as a bounded experiment to determine whether CoreAudio function interposition
// can achieve per-VM audio routing through VZ's internal audio path.
//
// Threading model: VZVirtualMachine must be used from a single serial queue
// (Apple requirement). All VZ interactions go through `vmQueue`. Public async
// methods bridge callers into that queue.

import Foundation
@preconcurrency import Virtualization
import os

import VortexCore

// MARK: - TrackAVMManager

/// Track A VM manager: VZ with native audio + CoreAudio interception.
///
/// ## How it differs from VortexVZ.VZVMManager
///
/// | Aspect               | VortexVZ (production)        | VortexInterception (Track A)     |
/// |----------------------|------------------------------|----------------------------------|
/// | Audio config         | None (vsock bridge)          | VZVirtioSoundDeviceConfiguration |
/// | Audio routing        | VsockAudioBridge             | AudioInterceptor (fishhook)      |
/// | Guest audio driver   | Custom vsock agent           | Standard virtio-snd              |
/// | Maturity             | Production path              | Experimental (2-week bound)      |
///
/// ## Usage
///
/// ```swift
/// let manager = TrackAVMManager(configuration: vmConfig)
///
/// // Install hooks BEFORE creating/starting the VM.
/// try AudioInterceptor.install(
///     targetOutputDeviceID: targetDevice,
///     targetInputDeviceID: nil
/// )
///
/// let vm = try await manager.createVM()
/// try await manager.start()
///
/// // ... VM runs with audio redirected to targetDevice ...
///
/// try await manager.stop()
/// AudioInterceptor.uninstall()
/// ```
public final class TrackAVMManager: @unchecked Sendable {

    // MARK: - Properties

    /// The VM configuration from VortexCore.
    public let configuration: VMConfiguration

    /// The underlying VZ virtual machine instance. `nil` until `createVM()`.
    private var virtualMachine: VZVirtualMachine?

    /// Serial queue for all VZ interactions (Apple requirement).
    private let vmQueue = DispatchQueue(label: "com.vortex.trackA-vm", qos: .userInteractive)

    /// Logger for VM lifecycle events.
    private let logger = Logger(subsystem: "com.vortex.interception", category: "TrackAVMManager")

    /// Delegate that receives VZ callbacks on vmQueue.
    private var vmDelegate: TrackAVMDelegate?

    /// Current VM state, updated by the delegate.
    private var _state: VMState = .stopped

    /// Lock protecting state reads.
    private var stateLock = os_unfair_lock()

    // MARK: - Init

    /// Create a Track A VM manager for the given configuration.
    ///
    /// - Parameter configuration: The VM configuration. The `audio` field
    ///   controls whether VZ's VZVirtioSoundDeviceConfiguration is added.
    public init(configuration: VMConfiguration) {
        self.configuration = configuration
    }

    // MARK: - State

    /// The current VM state.
    public var state: VMState {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return _state
    }

    private func setState(_ newState: VMState) {
        os_unfair_lock_lock(&stateLock)
        _state = newState
        os_unfair_lock_unlock(&stateLock)
        logger.info("State -> \(newState.rawValue)")
    }

    // MARK: - VM creation

    /// Build a `VZVirtualMachineConfiguration` from the VortexCore config and
    /// instantiate a `VZVirtualMachine`.
    ///
    /// **Track A difference:** This configuration includes
    /// `VZVirtioSoundDeviceConfiguration` with `VZHostAudioOutputStreamSink`
    /// (and optionally `VZHostAudioInputStreamSource`). VZ will create
    /// AudioUnit instances internally, which `AudioInterceptor` will redirect.
    ///
    /// - Returns: The created `VZVirtualMachine`.
    /// - Throws: `VortexError` if configuration is invalid or VZ rejects it.
    @discardableResult
    public func createVM() async throws -> VZVirtualMachine {
        try await withCheckedThrowingContinuation { continuation in
            vmQueue.async { [self] in
                do {
                    let vzConfig = try self.buildVZConfiguration()
                    try vzConfig.validate()

                    let vm = VZVirtualMachine(configuration: vzConfig, queue: self.vmQueue)
                    let delegate = TrackAVMDelegate(
                        logger: self.logger,
                        stateChanged: { [weak self] newState in
                            self?.setState(newState)
                        }
                    )
                    vm.delegate = delegate

                    self.virtualMachine = vm
                    self.vmDelegate = delegate
                    self.setState(.stopped)

                    self.logger.info("Track A VM created (audio enabled: \(self.configuration.audio.enabled))")
                    continuation.resume(returning: vm)
                } catch {
                    self.logger.error("Failed to create VM: \(error.localizedDescription)")
                    continuation.resume(throwing: VortexError.vmCreationFailed(
                        reason: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - macOS installation

    /// Install macOS from an IPSW restore image.
    ///
    /// This performs the initial macOS installation into the VM's boot disk.
    /// The VM must have been created via `createVM()` first.
    ///
    /// - Parameter ipsw: URL to the IPSW restore image file.
    /// - Throws: `VortexError.bootFailed` if installation fails.
    public func installMacOS(ipsw: URL) async throws {
        guard let vm = await getVM() else {
            throw VortexError.vmCreationFailed(reason: "VM not created. Call createVM() first.")
        }

        logger.info("Loading macOS restore image from \(ipsw.path)")

        let restoreImage = try await VZMacOSRestoreImage.image(from: ipsw)

        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VortexError.invalidRestoreImage(
                path: ipsw.path,
                reason: "No supported configuration found in restore image")
        }

        logger.info("""
            Restore image requirements: \
            minCPU=\(requirements.minimumSupportedCPUCount), \
            minMemory=\(requirements.minimumSupportedMemorySize / (1024*1024)) MiB
            """)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)

                self.logger.info("Starting macOS installation...")
                installer.install { [weak self] result in
                    switch result {
                    case .success:
                        self?.logger.info("macOS installation completed")
                        continuation.resume()
                    case .failure(let error):
                        self?.logger.error("macOS install failed: \(error.localizedDescription)")
                        continuation.resume(throwing: VortexError.bootFailed(
                            reason: "macOS install failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Start the virtual machine.
    ///
    /// **Important:** Install `AudioInterceptor` hooks *before* calling this.
    /// VZ creates its AudioUnit instances during or shortly after `vm.start()`.
    ///
    /// - Throws: `VortexError.vmStartFailed` if the VM cannot be started.
    public func start() async throws {
        guard let vm = await getVM() else {
            throw VortexError.vmStartFailed(reason: "VM not created. Call createVM() first.")
        }

        if configuration.audio.enabled && !AudioInterceptor.isInstalled {
            logger.warning(
                "Audio is enabled but AudioInterceptor hooks are not installed. VZ audio will route to system default device."
            )
        }

        setState(.starting)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                vm.start { [weak self] result in
                    switch result {
                    case .success:
                        self?.setState(.running)
                        continuation.resume()
                    case .failure(let error):
                        self?.setState(.error)
                        continuation.resume(throwing: VortexError.vmStartFailed(
                            reason: error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Request a graceful stop. The guest OS should initiate a clean shutdown.
    public func stop() async throws {
        guard let vm = await getVM() else { return }

        setState(.stopping)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                do {
                    try vm.requestStop()
                    // State will be updated to .stopped by the delegate callback.
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: VortexError.internalError(
                        reason: "Stop request failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Immediately terminate the VM without waiting for guest cooperation.
    public func forceStop() async throws {
        guard let vm = await getVM() else { return }

        do {
            try await vm.stop()
            setState(.stopped)
        } catch {
            throw VortexError.internalError(
                reason: "Force stop failed: \(error.localizedDescription)")
        }
    }

    /// Pause VM execution, freezing all vCPUs.
    public func pause() async throws {
        guard let vm = await getVM() else {
            throw VortexError.invalidStateTransition(from: .stopped, to: .paused)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                vm.pause { [weak self] result in
                    switch result {
                    case .success:
                        self?.setState(.paused)
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: VortexError.internalError(
                            reason: "Pause failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    /// Resume a paused VM.
    public func resume() async throws {
        guard let vm = await getVM() else {
            throw VortexError.invalidStateTransition(from: .stopped, to: .running)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                vm.resume { [weak self] result in
                    switch result {
                    case .success:
                        self?.setState(.running)
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: VortexError.internalError(
                            reason: "Resume failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    // MARK: - Internal: VZ configuration

    /// Build the VZ configuration. This is where Track A diverges from VortexVZ:
    /// we add `VZVirtioSoundDeviceConfiguration`.
    private func buildVZConfiguration() throws -> VZVirtualMachineConfiguration {
        let vzConfig = VZVirtualMachineConfiguration()

        // -- CPU & Memory --
        vzConfig.cpuCount = configuration.hardware.cpuCoreCount
        vzConfig.memorySize = configuration.hardware.memorySize

        // -- Platform --
        switch configuration.guestOS {
        case .macOS:
            vzConfig.platform = try buildMacPlatform()
            vzConfig.bootLoader = VZMacOSBootLoader()
        case .linuxARM64, .windowsARM:
            vzConfig.platform = VZGenericPlatformConfiguration()
            let efiBootLoader = VZEFIBootLoader()
            if let storePath = configuration.bootConfig.uefiStorePath {
                efiBootLoader.variableStore = VZEFIVariableStore(
                    url: URL(fileURLWithPath: storePath))
            }
            vzConfig.bootLoader = efiBootLoader
        }

        // -- Storage --
        vzConfig.storageDevices = try buildStorageDevices()

        // -- Network --
        vzConfig.networkDevices = buildNetworkDevices()

        // -- Display --
        vzConfig.graphicsDevices = [buildGraphicsDevice()]

        // -- Audio (Track A: VZ built-in, intercepted by AudioInterceptor) --
        if configuration.audio.enabled {
            vzConfig.audioDevices = buildAudioDevices()
            logger.info("VZ audio devices configured (Track A interception mode)")
        }

        // -- Entropy --
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // -- Memory Balloon --
        vzConfig.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        // -- Input devices (macOS vs generic) --
        if configuration.guestOS == .macOS {
            vzConfig.keyboards = [VZMacKeyboardConfiguration()]
            vzConfig.pointingDevices = [VZMacTrackpadConfiguration()]
        } else {
            vzConfig.keyboards = [VZUSBKeyboardConfiguration()]
            vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        // -- Shared Folders (VirtioFS) --
        var dirShares: [VZDirectorySharingDeviceConfiguration] = []
        for folder in configuration.sharedFolders {
            let hostURL = URL(fileURLWithPath: folder.hostPath)
            guard FileManager.default.fileExists(atPath: folder.hostPath) else { continue }
            let share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: hostURL, readOnly: folder.readOnly))
            let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: folder.tag)
            fsConfig.share = share
            dirShares.append(fsConfig)
        }
        vzConfig.directorySharingDevices = dirShares

        // -- Clipboard (macOS only via Spice agent) --
        if configuration.guestOS == .macOS && configuration.clipboard.enabled {
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
        if let rosetta = configuration.rosetta, rosetta.enabled,
           configuration.guestOS == .linuxARM64 {
            if VZLinuxRosettaDirectoryShare.availability == .installed {
                let rosettaShare = try VZLinuxRosettaDirectoryShare()
                let rosettaFS = VZVirtioFileSystemDeviceConfiguration(tag: rosetta.mountTag)
                rosettaFS.share = rosettaShare
                vzConfig.directorySharingDevices.append(rosettaFS)
            }
        }

        return vzConfig
    }

    // MARK: - Internal: platform

    /// Build `VZMacPlatformConfiguration` from boot config paths.
    private func buildMacPlatform() throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()

        guard let auxPath = configuration.bootConfig.auxiliaryStoragePath else {
            throw VortexError.invalidConfiguration(
                issues: ["macOS boot requires auxiliaryStoragePath"])
        }
        guard let idPath = configuration.bootConfig.machineIdentifierPath else {
            throw VortexError.invalidConfiguration(
                issues: ["macOS boot requires machineIdentifierPath"])
        }

        let auxURL = URL(fileURLWithPath: auxPath)
        let idURL = URL(fileURLWithPath: idPath)

        // Auxiliary storage (NVRAM)
        if FileManager.default.fileExists(atPath: auxPath) {
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxURL)
        } else {
            // For fresh installs, the hardware model comes from the IPSW.
            // This path is a fallback for re-opening existing VMs.
            let hwModelURL = auxURL.deletingLastPathComponent()
                .appendingPathComponent("hardwareModel.bin")
            guard let hwData = try? Data(contentsOf: hwModelURL),
                  let hwModel = VZMacHardwareModel(dataRepresentation: hwData) else {
                throw VortexError.vmCreationFailed(
                    reason: "Hardware model not found. Run macOS installation first.")
            }
            platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxURL,
                hardwareModel: hwModel)
            platform.hardwareModel = hwModel
        }

        // Machine identifier
        if FileManager.default.fileExists(atPath: idPath),
           let idData = try? Data(contentsOf: idURL),
           let identifier = VZMacMachineIdentifier(dataRepresentation: idData) {
            platform.machineIdentifier = identifier
        } else {
            let newID = VZMacMachineIdentifier()
            let parentDir = idURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true)
            try newID.dataRepresentation.write(to: idURL)
            platform.machineIdentifier = newID
        }

        // Hardware model (load from disk if not already set above)
        if platform.hardwareModel.dataRepresentation.isEmpty {
            let hwModelURL = auxURL.deletingLastPathComponent()
                .appendingPathComponent("hardwareModel.bin")
            if let hwData = try? Data(contentsOf: hwModelURL),
               let hwModel = VZMacHardwareModel(dataRepresentation: hwData) {
                platform.hardwareModel = hwModel
            }
        }

        return platform
    }

    // MARK: - Internal: storage

    private func buildStorageDevices() throws -> [VZStorageDeviceConfiguration] {
        try configuration.storage.disks.map { disk in
            let url = URL(fileURLWithPath: disk.imagePath)
            guard FileManager.default.fileExists(atPath: disk.imagePath) else {
                throw VortexError.fileNotFound(path: disk.imagePath)
            }

            let cachingMode: VZDiskImageCachingMode = {
                switch disk.cachingMode {
                case .automatic, .writeBack, .writeThrough, .none: return .automatic
                }
            }()
            let syncMode: VZDiskImageSynchronizationMode = {
                switch disk.syncMode {
                case .full: return .full
                case .unsafe: return .none
                }
            }()

            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: url,
                readOnly: disk.readOnly,
                cachingMode: cachingMode,
                synchronizationMode: syncMode)

            switch disk.deviceType {
            case .virtioBlock:
                return VZVirtioBlockDeviceConfiguration(attachment: attachment)
            case .usbMassStorage:
                return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
            }
        }
    }

    // MARK: - Internal: network

    private func buildNetworkDevices() -> [VZNetworkDeviceConfiguration] {
        configuration.network.interfaces.map { iface in
            let device = VZVirtioNetworkDeviceConfiguration()

            switch iface.mode {
            case .nat:
                device.attachment = VZNATNetworkDeviceAttachment()
            case .bridged(let hostInterface):
                if let bridgeIface = VZBridgedNetworkInterface.networkInterfaces
                    .first(where: { $0.identifier == hostInterface }) {
                    device.attachment = VZBridgedNetworkDeviceAttachment(interface: bridgeIface)
                } else {
                    logger.warning("Bridge interface '\(hostInterface)' not found, using NAT")
                    device.attachment = VZNATNetworkDeviceAttachment()
                }
            case .hostOnly:
                device.attachment = VZNATNetworkDeviceAttachment()
            }

            if let macString = iface.macAddress,
               let mac = VZMACAddress(string: macString) {
                device.macAddress = mac
            }
            return device
        }
    }

    // MARK: - Internal: graphics

    private func buildGraphicsDevice() -> VZGraphicsDeviceConfiguration {
        let display = configuration.display
        switch configuration.guestOS {
        case .macOS:
            let macGraphics = VZMacGraphicsDeviceConfiguration()
            macGraphics.displays = [
                VZMacGraphicsDisplayConfiguration(
                    widthInPixels: display.widthPixels,
                    heightInPixels: display.heightPixels,
                    pixelsPerInch: display.pixelsPerInch)
            ]
            return macGraphics
        case .linuxARM64, .windowsARM:
            let virtioGPU = VZVirtioGraphicsDeviceConfiguration()
            virtioGPU.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(
                    widthInPixels: display.widthPixels,
                    heightInPixels: display.heightPixels)
            ]
            return virtioGPU
        }
    }

    // MARK: - Internal: audio (Track A)

    /// Build VZ audio devices. This is the key Track A difference: we enable
    /// VZ's native virtio-snd path so it creates AudioUnit instances in-process,
    /// which AudioInterceptor hooks can redirect.
    private func buildAudioDevices() -> [VZAudioDeviceConfiguration] {
        let sound = VZVirtioSoundDeviceConfiguration()

        // Output stream (playback: guest audio -> host device).
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        sound.streams = [outputStream]

        // Input stream (capture: host microphone -> guest).
        if configuration.audio.input != nil {
            let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
            inputStream.source = VZHostAudioInputStreamSource()
            sound.streams.append(inputStream)
        }

        logger.debug("Audio config: \(sound.streams.count) stream(s)")
        return [sound]
    }

    // MARK: - Internal: helpers

    private func getVM() async -> VZVirtualMachine? {
        await withCheckedContinuation { continuation in
            vmQueue.async {
                continuation.resume(returning: self.virtualMachine)
            }
        }
    }
}

// MARK: - TrackAVMDelegate

/// VZVirtualMachineDelegate that translates VZ state callbacks to VMState.
private final class TrackAVMDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {

    private let logger: Logger
    private let stateChanged: (VMState) -> Void

    init(logger: Logger, stateChanged: @escaping (VMState) -> Void) {
        self.logger = logger
        self.stateChanged = stateChanged
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Guest initiated shutdown")
        stateChanged(.stopped)
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        logger.error("VM stopped with error: \(error.localizedDescription)")
        stateChanged(.error)
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        logger.warning("Network device disconnected: \(error.localizedDescription)")
        // Non-fatal; do not change VM state.
    }
}
