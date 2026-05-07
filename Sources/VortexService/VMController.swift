// VMController.swift -- Per-VM lifecycle controller with audio bridge management.
// VortexService
//
// Owns a VZVirtualMachine instance and exposes its state for the UI.
// Handles start/stop/pause/resume and audio bridge attach/detach.

import Foundation
import Observation
import Virtualization
import VortexAudio
import VortexCore
import VortexPersistence
import VortexVZ

// MARK: - VMController

/// Owns a `VZVirtualMachine` and exposes its state for the UI.
///
/// Each running VM gets exactly one controller. The controller manages:
/// - VM lifecycle (start, stop, pause, resume)
/// - VZ state observation and mapping to UI-visible properties
/// - Audio bridge attach/detach on VM start/stop
/// - Audio config persistence when settings change
/// - Guest connection state and audio device hot-plug monitoring
@MainActor
@Observable
public final class VMController: Identifiable {
    public let id: UUID
    public let vm: VZVirtualMachine
    public let manager: VZVMManager
    public var config: VMConfiguration

    public var stateLabel: String = "Stopped"
    public var isRunning: Bool = false
    public var isPaused: Bool = false
    public var canStart: Bool = true
    public var canStop: Bool = false
    public var errorMessage: String?
    public var showAudioSettings: Bool = false

    /// Whether the guest audio daemon has connected to the bridge.
    ///
    /// True when the bridge reports that a guest daemon has connected
    /// and sent a CONFIGURE + START sequence. Derived from the bridge's
    /// `isStreaming` property, polled periodically while the VM runs.
    public var isGuestConnected: Bool = false

    /// Warning message shown when a configured audio device disappears.
    /// Cleared when the device reappears or when audio settings change.
    public var audioDeviceWarning: String?

    /// Human-readable summary of the current audio routing.
    public var audioRoutingSummary: String {
        guard config.audio.enabled else { return "Audio disabled" }

        let outputName = config.audio.output?.hostDeviceName
        let inputName = config.audio.input?.hostDeviceName

        if outputName == nil && inputName == nil {
            return "No audio -- configure in Audio Settings"
        }

        let output = outputName ?? "None"
        let input = inputName ?? "None"
        return "Out: \(output) | In: \(input)"
    }

    private var stateObserver: VZVMStateObserver?
    private var audioBridge: VsockAudioBridge?
    private var bridgePollingTask: Task<Void, Never>?
    private var deviceWatcher: AudioDeviceEnumerator?

    public init(vm: VZVirtualMachine, manager: VZVMManager, config: VMConfiguration) {
        self.id = config.id
        self.vm = vm
        self.manager = manager
        self.config = config

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

    // MARK: - Lifecycle

    public func start() async {
        guard vm.canStart else { return }
        stateLabel = "Starting"
        canStart = false
        do {
            try await manager.start(vm)
            updateFromVZState()
            attachAudioBridge()
            startBridgePolling()
            startDeviceWatcher()
        } catch {
            errorMessage = error.localizedDescription
            stateLabel = "Error"
            canStart = true
        }
    }

    public func stop() async {
        guard vm.canRequestStop || vm.canStop else { return }
        stateLabel = "Stopping"
        canStop = false
        stopBridgePolling()
        stopDeviceWatcher()
        detachAudioBridge()
        do {
            try await manager.stop(vm)
            updateFromVZState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func pause() async {
        guard vm.canPause else { return }
        do {
            try await manager.pause(vm)
            updateFromVZState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func resume() async {
        guard vm.canResume else { return }
        do {
            try await manager.resume(vm)
            updateFromVZState()
        } catch {
            errorMessage = error.localizedDescription
        }
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

        VortexLog.service.debug("VM socket devices: \(self.vm.socketDevices.count)")
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
        canStart = state.canStart
        canStop = state.canStop
    }

    public func updateFromVZState() {
        let vzState = vm.state
        stateLabel = vzStateName(vzState).capitalized
        isRunning = (vzState == .running)
        isPaused = (vzState == .paused)
        canStart = vm.canStart
        canStop = vm.canRequestStop || vm.canStop
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
