// VMDisplayWindow.swift -- VM display window with toolbar and status bar.
// VortexGUI
//
// Opens when a VM is started. Shows VZVirtualMachineView filling the window,
// with a toolbar for power controls and audio settings, plus a status bar at
// the bottom showing VM state and audio routing info.

import SwiftUI
import Virtualization
import VortexCore

// MARK: - VMDisplayWindow

/// The VM display window, identified by VM UUID. Created by the WindowGroup scene.
struct VMDisplayWindow: View {
    let vmID: UUID
    @Environment(VMLibraryViewModel.self) private var viewModel
    @State private var controller: VMController?
    @State private var bootError: String?

    var body: some View {
        Group {
            if let controller = controller {
                VMDisplayContent(controller: controller)
            } else if let error = bootError {
                VMBootErrorView(message: error)
            } else {
                VMBootingView()
            }
        }
        .task {
            await prepareAndBoot()
        }
    }

    private func prepareAndBoot() async {
        // Check if already running.
        if let existing = viewModel.controller(for: vmID) {
            self.controller = existing
            return
        }

        // Prepare and boot.
        do {
            let ctrl = try viewModel.prepareVM(id: vmID)
            self.controller = ctrl
            // Small delay for the window to fully appear before starting.
            try await Task.sleep(for: .milliseconds(300))
            await ctrl.start()
        } catch {
            bootError = error.localizedDescription
        }
    }
}

// MARK: - Booting View

/// Shown while the VM is being prepared and booted.
private struct VMBootingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Starting VM...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

// MARK: - Boot Error View

/// Shown when the VM fails to boot.
private struct VMBootErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text("Failed to Start VM")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

// MARK: - VM Display Content

/// The main display content: VZVirtualMachineView + toolbar + status bar.
private struct VMDisplayContent: View {
    @Bindable var controller: VMController

    var body: some View {
        VStack(spacing: 0) {
            // VM display fills available space
            VMDisplayView(vm: controller.vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status bar at bottom
            VMStatusBar(controller: controller)
        }
        .navigationTitle(controller.config.identity.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Audio settings button
                Button {
                    controller.showAudioSettings = true
                } label: {
                    Label("Audio Settings", systemImage: "speaker.wave.2")
                }
                .help("Configure audio device routing")

                Divider()

                // Power controls
                if controller.canStart {
                    Button {
                        Task { await controller.start() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .help("Start VM")
                }

                if controller.isRunning {
                    Button {
                        Task { await controller.pause() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause VM execution")
                }

                if controller.isPaused {
                    Button {
                        Task { await controller.resume() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Resume VM execution")
                }

                if controller.canStop {
                    Button {
                        Task { await controller.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop VM")
                }
            }
        }
        .sheet(isPresented: $controller.showAudioSettings) {
            AudioSettingsView(
                audioConfig: $controller.config.audio,
                onApply: {
                    controller.applyAudioSettings()
                    controller.showAudioSettings = false
                },
                onDismiss: {
                    controller.showAudioSettings = false
                }
            )
        }
    }
}

// MARK: - Status Bar

/// Bottom status bar showing VM state and audio routing.
private struct VMStatusBar: View {
    let controller: VMController

    var body: some View {
        HStack(spacing: 12) {
            // State indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Text(controller.stateLabel)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Divider()
                .frame(height: 12)

            // Audio routing
            HStack(spacing: 4) {
                Image(systemName: audioIconName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(controller.audioRoutingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Connection indicator
            if controller.isRunning {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Error indicator
            if let error = controller.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var stateColor: Color {
        if controller.isRunning { return .green }
        if controller.isPaused { return .yellow }
        return .gray
    }

    private var audioIconName: String {
        if !controller.config.audio.enabled { return "speaker.slash.fill" }
        if controller.config.audio.output != nil { return "speaker.wave.2.fill" }
        return "speaker.fill"
    }
}
