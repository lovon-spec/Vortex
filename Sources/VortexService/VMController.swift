// VMController.swift -- Per-VM lifecycle controller with audio bridge management.
// VortexService
//
// Owns a VM backend instance and exposes its state for the UI.
// Handles start/stop/pause/resume and backend-specific attach/detach work.

import Foundation
import Observation
import Virtualization
import VortexAudio
import VortexCore
import VortexHV
import VortexLinux
import VortexPersistence
import VortexVZ

// MARK: - VMController

/// Owns one running VM backend and exposes its state for the UI.
///
/// Each running VM gets exactly one controller. The controller manages:
/// - VM lifecycle (start, stop, pause, resume)
/// - Backend state observation and mapping to UI-visible properties
/// - Audio bridge attach/detach on VZ VM start/stop
/// - Audio config persistence when settings change
/// - Guest connection state and audio device hot-plug monitoring
@MainActor
@Observable
public final class VMController: Identifiable {
    public let id: UUID
    public let vm: VZVirtualMachine?
    public let nativeLinuxVM: NativeLinuxVM?
    public let manager: VZVMManager?
    public var config: VMConfiguration

    public var stateLabel: String = "Stopped"
    public var isRunning: Bool = false
    public var isPaused: Bool = false
    public var canStart: Bool = true
    public var canPause: Bool = false
    public var canResume: Bool = false
    public var canStop: Bool = false
    public var errorMessage: String?
    public var showAudioSettings: Bool = false
    public var isStarting: Bool = false
    public var serialConsoleText: String = ""
    public var nativeFramebuffer: NativeLinuxFramebuffer?

    /// Whether the guest audio daemon has connected to the bridge.
    ///
    /// True when the bridge reports that a guest daemon has connected
    /// and sent a CONFIGURE + START sequence. Derived from the bridge's
    /// `isStreaming` property, polled periodically while the VM runs.
    public var isGuestConnected: Bool = false

    /// Warning message shown when a configured audio device disappears.
    /// Cleared when the device reappears or when audio settings change.
    public var audioDeviceWarning: String?

    /// vmnet networks that were reserved while creating this VM.
    public var vmnetNetworkStatuses: [VmnetNetworkStatus] = []

    /// Human-readable summary of the current audio routing.
    public var audioRoutingSummary: String {
        guard config.audio.enabled else { return "Audio disabled" }

        let outputName = config.audio.output?.hostDeviceName
        let inputName = config.audio.input?.hostDeviceName

        if outputName == nil && inputName == nil {
            if nativeLinuxVM != nil {
                return "System default audio"
            }
            return "No audio -- configure in Audio Settings"
        }

        let output = outputName ?? (nativeLinuxVM != nil ? "System default" : "None")
        let input = inputName ?? (nativeLinuxVM != nil ? "System default" : "None")
        return "Out: \(output) | In: \(input)"
    }

    private var stateObserver: VZVMStateObserver?
    private var audioBridge: VsockAudioBridge?
    private var bridgePollingTask: Task<Void, Never>?
    private var deviceWatcher: AudioDeviceEnumerator?
    @ObservationIgnored
    private nonisolated(unsafe) var ownerLock: VMOwnerLock?
    @ObservationIgnored
    private var didReleaseVmnetNetworks = false

    public init(
        vm: VZVirtualMachine,
        manager: VZVMManager,
        config: VMConfiguration,
        ownerLock: VMOwnerLock
    ) {
        self.id = config.id
        self.vm = vm
        self.nativeLinuxVM = nil
        self.manager = manager
        self.config = config
        self.ownerLock = ownerLock
        self.vmnetNetworkStatuses = VmnetNetworkRegistry.shared.statuses(
            for: config.network.interfaces
        )

        // Wire up the state observer.
        if let observer = manager.stateObserver(for: vm) {
            self.stateObserver = observer
            observer.onStateChange = { [weak self] state in
                Task { @MainActor in
                    self?.updateState(state)
                }
            }
            observer.onError = { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public init(
        nativeLinuxVM: NativeLinuxVM,
        config: VMConfiguration,
        ownerLock: VMOwnerLock
    ) {
        self.id = config.id
        self.vm = nil
        self.nativeLinuxVM = nativeLinuxVM
        self.manager = nil
        self.config = config
        self.ownerLock = ownerLock
        self.vmnetNetworkStatuses = []

        nativeLinuxVM.onSerialOutput = { [weak self] byte in
            Task { @MainActor in
                self?.appendSerialByte(byte)
            }
        }
        nativeLinuxVM.onFramebufferUpdated = { [weak self] framebuffer in
            Task { @MainActor in
                self?.nativeFramebuffer = framebuffer
            }
        }
        nativeLinuxVM.vm.lifecycle.onStateChange = { [weak self] state, _ in
            Task { @MainActor in
                self?.updateNativeState(state)
            }
        }
        updateNativeState(nativeLinuxVM.vm.lifecycle.state)
    }

    deinit {
        ownerLock?.release()
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !isStarting else {
            VortexLog.service.debug("Ignoring duplicate start request for VM \(self.config.id)")
            return
        }
        if let vm, !vm.canStart {
            updateFromVZState()
            VortexLog.service.debug("Ignoring start request for VM \(self.config.id) in state \(self.stateLabel)")
            return
        }
        if nativeLinuxVM != nil, !canStart {
            VortexLog.service.debug("Ignoring start request for VM \(self.config.id) in state \(self.stateLabel)")
            return
        }
        isStarting = true
        stateLabel = "Starting"
        canStart = false
        errorMessage = nil
        do {
            if let vm, let manager {
                try await manager.start(vm)
                updateFromVZState()
                attachAudioBridge()
                startBridgePolling()
                startDeviceWatcher()
            } else if let nativeLinuxVM {
                try await Task.detached {
                    try nativeLinuxVM.start()
                }.value
                updateNativeState(nativeLinuxVM.vm.lifecycle.state)
            }
        } catch {
            errorMessage = error.localizedDescription
            stateLabel = "Error"
            canStart = vm?.canStart ?? true
        }
        isStarting = false
    }

    public func stop() async {
        if let vm {
            guard vm.canRequestStop || vm.canStop else { return }
        } else {
            guard canStop else { return }
        }
        stateLabel = "Stopping"
        canStop = false
        stopBridgePolling()
        stopDeviceWatcher()
        detachAudioBridge()
        do {
            if let vm, let manager {
                try await manager.stop(vm)
                updateFromVZState()
            } else if let nativeLinuxVM {
                try await Task.detached {
                    try nativeLinuxVM.stop()
                }.value
                updateNativeState(nativeLinuxVM.vm.lifecycle.state)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func pause() async {
        guard canPause else { return }
        do {
            if let vm, let manager {
                try await manager.pause(vm)
                updateFromVZState()
            } else if let nativeLinuxVM {
                try await Task.detached {
                    try nativeLinuxVM.vm.pause()
                }.value
                updateNativeState(nativeLinuxVM.vm.lifecycle.state)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func resume() async {
        guard canResume else { return }
        do {
            if let vm, let manager {
                try await manager.resume(vm)
                updateFromVZState()
            } else if let nativeLinuxVM {
                try await Task.detached {
                    try nativeLinuxVM.vm.resume()
                }.value
                updateNativeState(nativeLinuxVM.vm.lifecycle.state)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func sendNativeKey(code: UInt16, pressed: Bool) {
        nativeLinuxVM?.sendKey(code: code, pressed: pressed)
    }

    public func sendNativePointer(
        x: UInt32,
        y: UInt32,
        leftButton: Bool,
        rightButton: Bool,
        middleButton: Bool
    ) {
        nativeLinuxVM?.sendPointer(
            x: x,
            y: y,
            leftButton: leftButton,
            rightButton: rightButton,
            middleButton: middleButton
        )
    }

    // MARK: - Audio Bridge

    private func attachAudioBridge() {
        let audioConfig = config.audio

        guard audioConfig.enabled else {
            VortexLog.service.info("Audio is disabled in VM config, skipping vsock bridge")
            return
        }

        guard audioConfig.output != nil || audioConfig.input != nil else {
            VortexLog.service.info("No audio devices configured -- open Audio Settings to select devices")
            return
        }

        guard let vm else { return }

        VortexLog.service.debug("VM socket devices: \(self.vm?.socketDevices.count ?? 0)")
        for (i, dev) in vm.socketDevices.enumerated() {
            VortexLog.service.debug("  device[\(i)]: \(String(describing: type(of: dev)))")
        }

        let bridge = VsockAudioBridge(vmID: config.id)

        // Wire the device-disconnect callback so the UI can show a warning
        // when a configured host audio device is hot-unplugged.
        bridge.onDeviceStateChanged = { [weak self] disconnected, direction, uid in
            Task { @MainActor in
                guard let self = self else { return }
                if disconnected {
                    self.audioDeviceWarning = "\(direction.rawValue.capitalized) device disconnected: \(uid)"
                    VortexLog.service.warning("Audio device disconnected (\(direction.rawValue)): \(uid)")
                } else {
                    self.audioDeviceWarning = nil
                    VortexLog.service.info("Audio device reconnected (\(direction.rawValue)): \(uid)")
                }
            }
        }

        do {
            try bridge.attach(to: vm, audioConfig: audioConfig)
            self.audioBridge = bridge
            VortexLog.service.info("Vsock audio bridge attached -- output: \(audioConfig.output?.hostDeviceName ?? "none"), input: \(audioConfig.input?.hostDeviceName ?? "none")")
            VortexLog.service.info("Listening on vsock port 5198 for guest daemon connection")
        } catch {
            VortexLog.service.error("Failed to attach vsock bridge: \(error)")
            errorMessage = "Audio bridge failed: \(error.localizedDescription)"
        }
    }

    /// Tears down the current audio bridge and resets connection state.
    private func detachAudioBridge() {
        audioBridge?.detach()
        audioBridge = nil
        isGuestConnected = false
        audioDeviceWarning = nil
    }

    /// Persists the current audio config to disk and restarts the audio bridge.
    ///
    /// Called by `AudioSettingsView` when the user presses Apply.
    public func applyAudioSettings() {
        let repo = VMRepository()
        do {
            try repo.update(config)
            VortexLog.service.info("Audio config saved for VM \(self.config.id)")
        } catch {
            errorMessage = "Failed to save audio settings: \(error.localizedDescription)"
            return
        }

        // Clear any stale device warning since settings just changed.
        audioDeviceWarning = nil

        // Restart the audio bridge with the new config if the VM is running.
        guard isRunning else { return }

        detachAudioBridge()
        attachAudioBridge()
        startBridgePolling()
    }

    // MARK: - Bridge State Polling

    /// Polls the audio bridge periodically to update `isGuestConnected`.
    ///
    /// The bridge's `isStreaming` property reflects whether the guest daemon
    /// has connected and is actively sending/receiving PCM. We poll it every
    /// second to update the UI status bar without requiring a callback from
    /// the bridge (which runs on a non-main dispatch queue).
    private func startBridgePolling() {
        stopBridgePolling()
        bridgePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let connected = self.audioBridge?.isStreaming ?? false
                if self.isGuestConnected != connected {
                    self.isGuestConnected = connected
                }
                // Also sync the device-disconnected flag.
                let disconnected = self.audioBridge?.deviceDisconnected ?? false
                if disconnected && self.audioDeviceWarning == nil {
                    self.audioDeviceWarning = "Audio device disconnected"
                } else if !disconnected && self.audioDeviceWarning != nil
                            && self.audioDeviceWarning?.contains("disconnected") == true {
                    self.audioDeviceWarning = nil
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopBridgePolling() {
        bridgePollingTask?.cancel()
        bridgePollingTask = nil
    }

    // MARK: - Device Watcher

    /// Starts watching for host audio device hot-plug events.
    ///
    /// When a device disappears that is currently configured for this VM,
    /// we set `audioDeviceWarning` so the status bar shows a warning.
    private func startDeviceWatcher() {
        let watcher = AudioDeviceEnumerator()
        self.deviceWatcher = watcher
        watcher.startWatching { [weak self] devices in
            Task { @MainActor in
                guard let self = self else { return }
                self.checkDevicePresence(against: devices)
            }
        }
    }

    private func stopDeviceWatcher() {
        deviceWatcher?.stopWatching()
        deviceWatcher = nil
    }

    /// Checks whether the currently configured output/input devices still
    /// exist in the provided device list. Sets `audioDeviceWarning` if a
    /// configured device has disappeared.
    private func checkDevicePresence(against devices: [AudioHostDevice]) {
        guard config.audio.enabled else { return }

        let deviceUIDs = Set(devices.map(\.uid))
        var warnings: [String] = []

        if let outputUID = config.audio.output?.hostDeviceUID,
           !deviceUIDs.contains(outputUID) {
            warnings.append("Output device \"\(config.audio.output?.hostDeviceName ?? outputUID)\" disconnected")
        }

        if let inputUID = config.audio.input?.hostDeviceUID,
           !deviceUIDs.contains(inputUID) {
            warnings.append("Input device \"\(config.audio.input?.hostDeviceName ?? inputUID)\" disconnected")
        }

        if warnings.isEmpty {
            // Clear warning only if it was a device-related one.
            if audioDeviceWarning != nil {
                audioDeviceWarning = nil
                VortexLog.service.info("All configured audio devices are present")
            }
        } else {
            audioDeviceWarning = warnings.joined(separator: "; ")
            VortexLog.service.warning("Audio device(s) missing: \(warnings.joined(separator: ", "))")
        }
    }

    // MARK: - State Mapping

    private func updateState(_ state: VMState) {
        stateLabel = state.rawValue.capitalized
        isRunning = (state == .running)
        isPaused = (state == .paused)
        isStarting = (state == .starting)
        canStart = state.canStart
        canPause = state.canPause
        canResume = state.canResume
        canStop = state.canStop
    }

    public func updateFromVZState() {
        guard let vm else {
            if let nativeLinuxVM {
                updateNativeState(nativeLinuxVM.vm.lifecycle.state)
            }
            return
        }
        let vzState = vm.state
        stateLabel = vzStateName(vzState).capitalized
        isRunning = (vzState == .running)
        isPaused = (vzState == .paused)
        isStarting = (vzState == .starting)
        canStart = vm.canStart
        canPause = vm.canPause
        canResume = vm.canResume
        canStop = vm.canRequestStop || vm.canStop
    }

    private func updateNativeState(_ state: VortexHV.VMLifecycle.State) {
        stateLabel = state.rawValue.capitalized
        isRunning = (state == .running)
        isPaused = (state == .paused)
        isStarting = (state == .starting)
        canStart = (state == .stopped || state == .error)
        canPause = (state == .running)
        canResume = (state == .paused)
        canStop = (state == .running || state == .paused || state == .error)
        if state == .error {
            errorMessage = nativeLinuxVM?.vm.lifecycle.errorMessage ?? errorMessage
        }
    }

    private func appendSerialByte(_ byte: UInt8) {
        switch byte {
        case 0x08, 0x7F:
            if !serialConsoleText.isEmpty {
                serialConsoleText.removeLast()
            }
        case 0x0D:
            break
        default:
            serialConsoleText.append(Character(UnicodeScalar(byte)))
        }

        let maxCharacters = 64 * 1024
        if serialConsoleText.count > maxCharacters {
            serialConsoleText.removeFirst(serialConsoleText.count - maxCharacters)
        }
    }

    public func releaseOwnerLock() {
        releaseVmnetNetworks()
        ownerLock?.release()
        ownerLock = nil
    }

    private func releaseVmnetNetworks() {
        guard !didReleaseVmnetNetworks else { return }
        didReleaseVmnetNetworks = true
        VmnetNetworkRegistry.shared.releaseNetworks(for: config.network.interfaces)
        vmnetNetworkStatuses = []
    }

    private func vzStateName(_ state: VZVirtualMachine.State) -> String {
        switch state {
        case .stopped:   return "stopped"
        case .running:   return "running"
        case .paused:    return "paused"
        case .error:     return "error"
        case .starting:  return "starting"
        case .stopping:  return "stopping"
        case .resuming:  return "resuming"
        case .pausing:   return "pausing"
        case .saving:    return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown"
        }
    }
}
