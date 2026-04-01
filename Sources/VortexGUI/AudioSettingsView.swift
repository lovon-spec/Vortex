// AudioSettingsView.swift — Per-VM audio device selection UI.
// VortexGUI
//
// Presents dropdown menus for selecting host output and input audio devices
// for a specific VM. Selections are persisted to config.json via VMRepository
// and take effect on the next audio bridge attach (or immediately if applied
// while the bridge is running).

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
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("Audio Settings")
                .font(.headline)

            if let error = enumerationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Output device picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Output Device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Output", selection: $selectedOutputUID) {
                    Text("None (disabled)")
                        .tag(Self.noneUID)

                    ForEach(outputDevices) { device in
                        Text("\(device.name)")
                            .tag(device.uid)
                    }
                }
                .labelsHidden()

                if let uid = effectiveOutputUID {
                    Text("UID: \(uid)")
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Input device picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Input", selection: $selectedInputUID) {
                    Text("None (disabled)")
                        .tag(Self.noneUID)

                    ForEach(inputDevices) { device in
                        Text("\(device.name)")
                            .tag(device.uid)
                    }
                }
                .labelsHidden()

                if let uid = effectiveInputUID {
                    Text("UID: \(uid)")
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Audio enabled toggle
            Toggle("Audio Enabled", isOn: $audioConfig.enabled)
                .font(.subheadline)

            Divider()

            // Action buttons
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
            }
        }
        .padding(20)
        .frame(width: 380)
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
