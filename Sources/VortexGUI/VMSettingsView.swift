// VMSettingsView.swift -- Tabbed VM settings sheet.
// VortexGUI
//
// A tabbed settings view presented as a sheet from the library detail pane.
// Tabs: General, Hardware, Display, Network, Audio, Sharing.
//
// Hardware changes require a VM restart when the VM is running -- the view
// shows a warning badge in that case and disables hardware editing.

import os
import SwiftUI
import VortexAudio
import VortexCore
import VortexPersistence

// MARK: - Settings Tab

/// Available tabs in the VM settings view.
enum SettingsTab: String, CaseIterable {
    case general = "General"
    case hardware = "Hardware"
    case display = "Display"
    case network = "Network"
    case audio = "Audio"
    case sharing = "Sharing"

    var icon: String {
        switch self {
        case .general:  return "gearshape"
        case .hardware: return "cpu"
        case .display:  return "display"
        case .network:  return "network"
        case .audio:    return "speaker.wave.2"
        case .sharing:  return "folder"
        }
    }
}

// MARK: - VMSettingsView

/// Tabbed settings sheet for editing a VM's configuration.
struct VMSettingsView: View {

    /// The configuration being edited. A mutable copy is made internally.
    let config: VMConfiguration

    /// Whether the VM is currently running (hardware edits are disabled).
    let isRunning: Bool

    /// Callback invoked when the user saves changes.
    var onSave: (VMConfiguration) -> Void

    /// Callback to dismiss the sheet.
    var onDismiss: () -> Void

    // MARK: - State

    @State private var selectedTab: SettingsTab = .general
    @State private var editedConfig: VMConfiguration
    @State private var hasChanges: Bool = false
    @State private var saveError: String?

    // Sharing state
    @State private var showFolderPicker: Bool = false

    init(
        config: VMConfiguration,
        isRunning: Bool,
        onSave: @escaping (VMConfiguration) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.config = config
        self.isRunning = isRunning
        self.onSave = onSave
        self.onDismiss = onDismiss
        self._editedConfig = State(initialValue: config)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            settingsHeader
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 16)

            // Tab bar
            tabBar
                .padding(.horizontal, 24)
                .padding(.vertical, 10)

            Divider()
                .padding(.horizontal, 16)

            // Tab content
            Group {
                switch selectedTab {
                case .general:  generalTab
                case .hardware: hardwareTab
                case .display:  displayTab
                case .network:  networkTab
                case .audio:    audioTab
                case .sharing:  sharingTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Error banner
            if let error = saveError {
                errorBanner(error)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            Divider()
                .padding(.horizontal, 16)

            // Action buttons
            actionButtons
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 540, height: 480)
        .onChange(of: editedConfig) {
            hasChanges = editedConfig != config
        }
    }

    private var currentMemoryGiB: Int {
        max(
            HardwareProfile.minimumMemoryGiB,
            Int(editedConfig.hardware.memorySize / HardwareProfile.bytesPerGiB)
        )
    }

    private var maxEditableMemoryGiB: Int {
        max(HardwareProfile.maximumMemoryGiB, currentMemoryGiB)
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("VM Settings")
                    .font(.headline)
                Text(config.identity.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.green.opacity(0.1))
                .clipShape(Capsule())
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.rawValue) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.caption2)
                        Text(tab.rawValue)
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedTab == tab ? Color.blue.opacity(0.15) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? .blue : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VM Name")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextField("Name", text: $editedConfig.identity.name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextEditor(text: Binding(
                        get: { editedConfig.identity.notes ?? "" },
                        set: { editedConfig.identity.notes = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.body)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("VM ID")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(editedConfig.id.uuidString)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Guest OS")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(editedConfig.guestOS.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Created")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(editedConfig.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Hardware Tab

    private var hardwareTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isRunning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text("Hardware settings cannot be changed while the VM is running. Stop the VM first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // CPU
                HStack {
                    Label("CPU Cores", systemImage: "cpu")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Stepper(
                        "\(editedConfig.hardware.cpuCoreCount) cores",
                        value: $editedConfig.hardware.cpuCoreCount,
                        in: HardwareProfile.minimumCPUCores...HardwareProfile.maximumCPUCores
                    )
                    .frame(width: 160)
                    .disabled(isRunning)
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Memory
                HStack {
                    Label("Memory", systemImage: "memorychip")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Stepper(
                        "\(currentMemoryGiB) GB",
                        value: Binding(
                            get: { currentMemoryGiB },
                            set: { editedConfig.hardware.memorySize = UInt64($0) * HardwareProfile.bytesPerGiB }
                        ),
                        in: HardwareProfile.minimumMemoryGiB...maxEditableMemoryGiB
                    )
                    .frame(width: 160)
                    .disabled(isRunning)
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Disk (read-only display)
                HStack {
                    Label("Boot Disk", systemImage: "internaldrive")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    if let disk = editedConfig.storage.bootDisk {
                        Text(disk.sizeDisplayString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("None")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("Disk size cannot be changed after creation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Display Tab

    private var displayTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Resolution
                HStack {
                    Label("Resolution", systemImage: "display")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(editedConfig.display.widthPixels) x \(editedConfig.display.heightPixels)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // PPI
                HStack {
                    Label("Pixels Per Inch", systemImage: "ruler")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Stepper(
                        "\(editedConfig.display.pixelsPerInch) PPI",
                        value: $editedConfig.display.pixelsPerInch,
                        in: 72...326
                    )
                    .frame(width: 160)
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Auto-resizing toggle
                Toggle(isOn: $editedConfig.display.automaticResizing) {
                    Label("Automatic Display Resizing", systemImage: "rectangle.expand.vertical")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .toggleStyle(.switch)
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Aspect ratio info
                HStack {
                    Text("Aspect Ratio")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(editedConfig.display.aspectRatioDescription)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Network Tab

    private var networkTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if editedConfig.network.interfaces.isEmpty {
                    HStack {
                        Image(systemName: "network.slash")
                            .foregroundStyle(.tertiary)
                        Text("No network interfaces configured.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(Array(editedConfig.network.interfaces.enumerated()), id: \.element.id) { index, iface in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(iface.label ?? "Interface \(index + 1)", systemImage: "network")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                networkModeText(iface.mode)
                            }

                            if let mac = iface.macAddress {
                                HStack {
                                    Text("MAC Address")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Text(mac)
                                        .font(.caption)
                                        .monospaced()
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(12)
                        .background(.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Text("Network interface changes require a VM restart.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func networkModeText(_ mode: NetworkMode) -> some View {
        let text: String
        switch mode {
        case .nat:
            text = "NAT"
        case .bridged(let iface):
            text = "Bridged (\(iface))"
        case .hostOnly:
            text = "Host Only"
        }
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.blue.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        AudioSettingsView(
            audioConfig: $editedConfig.audio,
            onApply: {
                // No-op: save is handled by the parent action buttons.
            },
            onDismiss: {
                // No-op: dismiss is handled by the parent.
            }
        )
    }

    // MARK: - Sharing Tab

    private var sharingTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Shared Folders")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer()

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!editedConfig.guestOS.supportsSharedFolders)
                }

                if !editedConfig.guestOS.supportsSharedFolders {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text("Shared folders are not supported for \(editedConfig.guestOS.displayName) guests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if editedConfig.sharedFolders.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No shared folders configured.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(editedConfig.sharedFolders) { folder in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.tag)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(folder.hostPath)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if folder.readOnly {
                                Text("Read-only")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.gray.opacity(0.2))
                                    .clipShape(Capsule())
                            }

                            Button {
                                editedConfig.sharedFolders.removeAll { $0.id == folder.id }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove shared folder")
                        }
                        .padding(10)
                        .background(.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let tag = url.lastPathComponent
            let folder = SharedFolderConfig(
                tag: tag,
                hostPath: url.path,
                readOnly: false
            )
            editedConfig.sharedFolders.append(folder)
        case .failure(let error):
            VortexLog.gui.error("Folder picker failed: \(error.localizedDescription)")
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
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1))
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

            Button("Save") {
                saveChanges()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(!hasChanges)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Save

    private func saveChanges() {
        saveError = nil

        let updated = editedConfig.touchingModifiedDate()
        let repo = VMRepository()

        do {
            try repo.update(updated)
            VortexLog.gui.info("VM settings saved: \(updated.identity.name)")
            onSave(updated)
        } catch {
            VortexLog.gui.error("Failed to save VM settings: \(error.localizedDescription)")
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }
}
