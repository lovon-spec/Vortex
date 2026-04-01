// VMController.swift -- Per-VM lifecycle controller with audio bridge management.
// VortexGUI
//
// Owns a VZVirtualMachine instance and exposes its state for the UI.
// Handles start/stop/pause/resume and audio bridge attach/detach.

import Foundation
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
@MainActor
@Observable
final class VMController: Identifiable {
    let id: UUID
    let vm: VZVirtualMachine
    let manager: VZVMManager
    var config: VMConfiguration

    var stateLabel: String = "Stopped"
    var isRunning: Bool = false
    var isPaused: Bool = false
    var canStart: Bool = true
    var canStop: Bool = false
    var errorMessage: String?
    var showAudioSettings: Bool = false

    /// Human-readable summary of the current audio routing.
    var audioRoutingSummary: String {
        guard config.audio.enabled else { return "Audio disabled" }
        let output = config.audio.output?.hostDeviceName ?? "System Default"
        let input = config.audio.input?.hostDeviceName ?? "None"
        return "Out: \(output) | In: \(input)"
    }

    private var stateObserver: VZVMStateObserver?
    private var audioBridge: VsockAudioBridge?

    init(vm: VZVirtualMachine, manager: VZVMManager, config: VMConfiguration) {
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

    func start() async {
        guard vm.canStart else { return }
        stateLabel = "Starting"
        canStart = false
        do {
            try await manager.start(vm)
            updateFromVZState()
            attachAudioBridge()
        } catch {
            errorMessage = error.localizedDescription
            stateLabel = "Error"
            canStart = true
        }
    }

    func stop() async {
        guard vm.canRequestStop || vm.canStop else { return }
        stateLabel = "Stopping"
        canStop = false
        audioBridge?.detach()
        audioBridge = nil
        do {
            try await manager.stop(vm)
            updateFromVZState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause() async {
        guard vm.canPause else { return }
        do {
            try await manager.pause(vm)
            updateFromVZState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume() async {
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
            VortexLog.gui.info("Audio is disabled in VM config, skipping vsock bridge")
            return
        }

        guard audioConfig.output != nil || audioConfig.input != nil else {
            VortexLog.gui.info("No audio devices configured -- open Audio Settings to select devices")
            return
        }

        VortexLog.gui.debug("VM socket devices: \(self.vm.socketDevices.count)")
        for (i, dev) in vm.socketDevices.enumerated() {
            VortexLog.gui.debug("  device[\(i)]: \(String(describing: type(of: dev)))")
        }

        let bridge = VsockAudioBridge(vmID: config.id)
        do {
            try bridge.attach(to: vm, audioConfig: audioConfig)
            self.audioBridge = bridge
            VortexLog.gui.info("Vsock audio bridge attached -- output: \(audioConfig.output?.hostDeviceName ?? "none"), input: \(audioConfig.input?.hostDeviceName ?? "none")")
            VortexLog.gui.info("Listening on vsock port 5198 for guest daemon connection")
        } catch {
            VortexLog.gui.error("Failed to attach vsock bridge: \(error)")
        }
    }

    /// Persists the current audio config to disk and restarts the audio bridge.
    ///
    /// Called by `AudioSettingsView` when the user presses Apply.
    func applyAudioSettings() {
        let repo = VMRepository()
        do {
            try repo.update(config)
            VortexLog.gui.info("Audio config saved for VM \(self.config.id)")
        } catch {
            errorMessage = "Failed to save audio settings: \(error.localizedDescription)"
            return
        }

        // Restart the audio bridge with the new config if the VM is running.
        guard isRunning else { return }

        audioBridge?.detach()
        audioBridge = nil
        attachAudioBridge()
    }

    // MARK: - State Mapping

    private func updateState(_ state: VMState) {
        stateLabel = state.rawValue.capitalized
        isRunning = (state == .running)
        isPaused = (state == .paused)
        canStart = state.canStart
        canStop = state.canStop
    }

    func updateFromVZState() {
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
