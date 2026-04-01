// AudioSettingsView.swift -- Per-VM audio device selection UI.
// VortexGUI
//
// Presents dropdown menus for selecting host output and input audio devices
// for a specific VM. Selections are persisted to config.json via VMRepository
// and take effect on the next audio bridge attach (or immediately if applied
// while the bridge is running).
//
// Styled with section headers, UID display, and muted dark theme to match
// the Vortex aesthetic.

import SwiftUI
import VortexAudio
import VortexCore

// MARK: - AudioSettingsView

/// Sheet view for selecting per-VM audio input and output devices.
///
/// **Threading:** All UI work happens on `@MainActor`. Device enumeration
/// is synchronous (CoreAudio HAL calls) but fast -- performed inline when
/// the sheet appears.
struct AudioSettingsView: View {

    /// The current audio config to edit. Bound to the controller's config.
    @Binding var audioConfig: AudioConfig

    /// Callback invoked when the user presses Apply.
    var onApply: () -> Void

    /// Callback to dismiss the sheet.
    var onDismiss: () -> Void

    // MARK: - Local state

    @State private var outputDevices: [AudioHostDevice] = []
    @State private var inputDevices: [AudioHostDevice] = []
    @State private var selectedOutputUID: String = ""
    @State private var selectedInputUID: String = ""
    @State private var enumerationError: String?
    @State private var hasChanges: Bool = false

    /// Sentinel UID representing "None" (disabled).
    private static let noneUID = "__none__"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Divider()
                .padding(.horizontal, 16)

            // Error banner
            if let error = enumerationError {
                errorBanner(error)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            // Output device section
            deviceSection(
                title: "Output Device",
                icon: "speaker.wave.2.fill",
                selection: $selectedOutputUID,
                devices: outputDevices,
                uid: effectiveOutputUID
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)

            // Input device section
            deviceSection(
                title: "Input Device",
                icon: "mic.fill",
                selection: $selectedInputUID,
                devices: inputDevices,
                uid: effectiveInputUID
            )
            .padding(.horizontal, 24)
            .padding(.top, 16)

            // Audio enabled toggle
            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 20)

            Toggle(isOn: $audioConfig.enabled) {
                Label("Audio Enabled", systemImage: audioConfig.enabled ? "speaker.wave.2" : "speaker.slash")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()
                .padding(.horizontal, 16)

            // Action buttons
            actionButtons
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 420)
        .onAppear {
            refreshDevices()
            loadCurrentSelections()
        }
        .onChange(of: selectedOutputUID) {
            updateHasChanges()
        }
        .onChange(of: selectedInputUID) {
            updateHasChanges()
        }
        .onChange(of: audioConfig.enabled) {
            updateHasChanges()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Settings")
                    .font(.headline)
                Text("Configure host audio device routing for this VM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Device Section

    private func deviceSection(
        title: String,
        icon: String,
        selection: Binding<String>,
        devices: [AudioHostDevice],
        uid: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            // Picker
            Picker(title, selection: selection) {
                Text("None (disabled)")
                    .tag(Self.noneUID)

                if !devices.isEmpty {
                    Divider()
                }

                ForEach(devices) { device in
                    Text(device.name)
                        .tag(device.uid)
                }
            }
            .labelsHidden()

            // UID display
            if let uid = uid {
                HStack(spacing: 4) {
                    Text("UID:")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Text(uid)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Apply") {
                applySelections()
                onApply()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Computed

    /// The UID to display under the output picker, or nil if "None".
    private var effectiveOutputUID: String? {
        selectedOutputUID == Self.noneUID ? nil : selectedOutputUID
    }

    /// The UID to display under the input picker, or nil if "None".
    private var effectiveInputUID: String? {
        selectedInputUID == Self.noneUID ? nil : selectedInputUID
    }

    // MARK: - Device enumeration

    /// Queries CoreAudio for the current device list.
    private func refreshDevices() {
        let enumerator = AudioDeviceEnumerator()
        do {
            let all = try enumerator.allDevices()
            outputDevices = all.filter(\.isOutput)
            inputDevices = all.filter(\.isInput)
            enumerationError = nil
        } catch {
            enumerationError = "Failed to enumerate audio devices: \(error)"
            outputDevices = []
            inputDevices = []
        }
    }

    /// Sets the picker selections from the current audioConfig.
    private func loadCurrentSelections() {
        selectedOutputUID = audioConfig.output?.hostDeviceUID ?? Self.noneUID
        selectedInputUID = audioConfig.input?.hostDeviceUID ?? Self.noneUID

        // If the previously selected device is no longer present, reset to None.
        if selectedOutputUID != Self.noneUID,
           !outputDevices.contains(where: { $0.uid == selectedOutputUID }) {
            selectedOutputUID = Self.noneUID
        }
        if selectedInputUID != Self.noneUID,
           !inputDevices.contains(where: { $0.uid == selectedInputUID }) {
            selectedInputUID = Self.noneUID
        }

        // Reset change tracking after loading.
        hasChanges = false
    }

    /// Checks whether the current selections differ from the config.
    private func updateHasChanges() {
        let currentOutputUID = audioConfig.output?.hostDeviceUID ?? Self.noneUID
        let currentInputUID = audioConfig.input?.hostDeviceUID ?? Self.noneUID
        hasChanges = (selectedOutputUID != currentOutputUID)
            || (selectedInputUID != currentInputUID)
    }

    /// Writes the picker selections back into the audioConfig binding.
    private func applySelections() {
        if selectedOutputUID == Self.noneUID {
            audioConfig.output = nil
        } else if let device = outputDevices.first(where: { $0.uid == selectedOutputUID }) {
            audioConfig.output = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
        }

        if selectedInputUID == Self.noneUID {
            audioConfig.input = nil
        } else if let device = inputDevices.first(where: { $0.uid == selectedInputUID }) {
            audioConfig.input = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
        }

        hasChanges = false
    }
}
