// VortexGUIApp.swift — Minimal macOS app that boots a VM and shows its display.
// VortexGUI
//
// Usage:
//   VortexGUI <vm-uuid>       — boot and display the specified VM
//   VortexGUI                 — show a picker of available VMs
//
// After building, the binary must be codesigned with Vortex.entitlements:
//   codesign --sign - --entitlements Vortex.entitlements --force \
//       .build/arm64-apple-macosx/debug/VortexGUI

import SwiftUI
import Virtualization
import VortexAudio
import VortexCore
import VortexPersistence
import VortexVZ

// MARK: - App Entry Point

@main
struct VortexGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 800)
    }
}

// MARK: - App Delegate

/// Minimal `NSApplicationDelegate` that ensures the app activates properly
/// when launched from the terminal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Required for a CLI-launched binary to show windows and appear in Dock
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Root View

/// Top-level view that either shows the VM display (if a UUID was passed on
/// the command line) or a simple VM picker list.
struct RootView: View {
    @State private var viewModel = RootViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.mode {
                case .loading:
                    ProgressView("Loading...")
                        .navigationTitle("Vortex")
                case .picker(let configs):
                    VMPickerView(configs: configs) { config in
                        viewModel.select(config)
                    }
                case .display(let controller):
                    VMWindowView(controller: controller)
                case .error(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(message)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Vortex — Error")
                }
            }
        }
        .task {
            await viewModel.bootstrap()
        }
    }
}

// MARK: - Root View Model

/// Drives the top-level navigation: parse CLI args, load configs, create VM.
@MainActor
@Observable
final class RootViewModel {
    enum Mode {
        case loading
        case picker([VMConfiguration])
        case display(VMController)
        case error(String)
    }

    var mode: Mode = .loading

    func bootstrap() async {
        // Check for a UUID on the command line.
        let args = ProcessInfo.processInfo.arguments
        // args[0] is the executable path; args[1] would be the UUID if provided.
        if args.count > 1, let uuid = UUID(uuidString: args[1]) {
            await bootVM(id: uuid)
        } else {
            await showPicker()
        }
    }

    func select(_ config: VMConfiguration) {
        mode = .loading
        Task {
            await bootVM(id: config.id)
        }
    }

    private func showPicker() async {
        let repo = VMRepository()
        do {
            let configs = try repo.loadAll()
            if configs.isEmpty {
                mode = .error("No VMs found.\nCreate a VM with VortexCLI first.")
            } else {
                mode = .picker(configs)
            }
        } catch {
            mode = .error("Failed to load VMs: \(error.localizedDescription)")
        }
    }

    private func bootVM(id: UUID) async {
        let repo = VMRepository()
        let manager = VZVMManager()

        do {
            let config = try repo.load(id: id)
            let vm = try manager.createVM(config: config)
            let controller = VMController(
                vm: vm,
                manager: manager,
                config: config
            )
            mode = .display(controller)
            // Auto-start after a short delay to let the window appear.
            try await Task.sleep(for: .milliseconds(200))
            await controller.start()
        } catch {
            mode = .error("Failed to boot VM \(id):\n\(error.localizedDescription)")
        }
    }
}

// MARK: - VM Controller

/// Owns a `VZVirtualMachine` and exposes its state for the UI.
@MainActor
@Observable
final class VMController {
    let vm: VZVirtualMachine
    let manager: VZVMManager
    let config: VMConfiguration

    var stateLabel: String = "Stopped"
    var isRunning: Bool = false
    var isPaused: Bool = false
    var canStart: Bool = true
    var canStop: Bool = false
    var errorMessage: String?

    private var stateObserver: VZVMStateObserver?
    private var audioBridge: VsockAudioBridge?

    init(vm: VZVirtualMachine, manager: VZVMManager, config: VMConfiguration) {
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

    func start() async {
        guard vm.canStart else { return }
        stateLabel = "Starting"
        canStart = false
        do {
            try await manager.start(vm)
            updateFromVZState()
            // Attach vsock audio bridge after VM starts
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

    private func attachAudioBridge() {
        // Resolve audio devices — try BlackHole 16ch for output, BlackHole 2ch for input
        // Fall back to whatever is in the VM config, or skip if no devices found
        let enumerator = AudioDeviceEnumerator()
        let allDevices = (try? enumerator.allDevices()) ?? []

        // Always try to set up audio routing — use config if present, otherwise auto-detect BlackHole
        var audioConfig = config.audio
        audioConfig.enabled = true
        if audioConfig.output == nil, let bh16 = allDevices.first(where: { $0.name == "BlackHole 16ch" && $0.isOutput }) {
            audioConfig.output = AudioEndpointConfig(hostDeviceUID: bh16.uid, hostDeviceName: bh16.name)
        }
        if audioConfig.input == nil, let bh2 = allDevices.first(where: { $0.name == "BlackHole 2ch" && $0.isInput }) {
            audioConfig.input = AudioEndpointConfig(hostDeviceUID: bh2.uid, hostDeviceName: bh2.name)
        }

        guard audioConfig.output != nil || audioConfig.input != nil else {
            print("[audio] No audio devices configured, skipping vsock bridge")
            return
        }

        print("[audio] VM socket devices: \(vm.socketDevices.count)")
        for (i, dev) in vm.socketDevices.enumerated() {
            print("[audio]   device[\(i)]: \(type(of: dev))")
        }

        let bridge = VsockAudioBridge(vmID: config.id)
        do {
            try bridge.attach(to: vm, audioConfig: audioConfig)
            self.audioBridge = bridge
            print("[audio] Vsock audio bridge attached — output: \(audioConfig.output?.hostDeviceName ?? "none"), input: \(audioConfig.input?.hostDeviceName ?? "none")")
            print("[audio] Listening on vsock port 5198 for guest daemon connection...")
        } catch {
            print("[audio] Failed to attach vsock bridge: \(error)")
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

    private func updateState(_ state: VMState) {
        stateLabel = state.rawValue.capitalized
        isRunning = (state == .running)
        isPaused = (state == .paused)
        canStart = state.canStart
        canStop = state.canStop
    }

    private func updateFromVZState() {
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

// MARK: - VM Window View

/// The main VM display view with a toolbar for Start/Stop/Pause controls.
struct VMWindowView: View {
    let controller: VMController

    var body: some View {
        ZStack {
            VMDisplayView(vm: controller.vm)

            // Overlay error banner at the bottom if something went wrong.
            if let error = controller.errorMessage {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .lineLimit(2)
                        Spacer()
                        Button("Dismiss") {
                            controller.errorMessage = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle("\(controller.config.identity.name) — \(controller.stateLabel)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if controller.canStart {
                    Button {
                        Task { await controller.start() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                }

                if controller.isRunning {
                    Button {
                        Task { await controller.pause() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                }

                if controller.isPaused {
                    Button {
                        Task { await controller.resume() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                }

                if controller.canStop {
                    Button {
                        Task { await controller.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }
        }
    }
}

// MARK: - VM Picker View

/// Simple list of available VMs for selection when no UUID is provided.
struct VMPickerView: View {
    let configs: [VMConfiguration]
    let onSelect: (VMConfiguration) -> Void

    var body: some View {
        List(configs) { config in
            Button {
                onSelect(config)
            } label: {
                HStack {
                    Image(systemName: config.identity.iconName ?? "desktopcomputer")
                        .font(.title2)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.identity.name)
                            .font(.headline)
                        Text("\(config.guestOS.rawValue) — \(config.hardware.cpuCoreCount) cores, \(config.hardware.memorySize / (1024*1024*1024)) GB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(config.id.uuidString.prefix(8))
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
        .navigationTitle("Select a VM")
    }
}
