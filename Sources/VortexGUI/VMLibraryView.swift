// VMLibraryView.swift -- Main window: sidebar VM list + detail pane.
// VortexGUI
//
// NavigationSplitView with a sidebar showing all VMs (name, icon, status LED)
// and a detail pane showing the selected VM's info and action buttons.
// Includes toolbar buttons for creating new VMs and accessing VM settings.

import SwiftUI
import VortexCore

// MARK: - VMLibraryView

/// The main library window showing all VMs in a sidebar/detail layout.
struct VMLibraryView: View {
    @Environment(VMLibraryViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var vm = viewModel

        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 450)
        .task {
            viewModel.loadConfigurations()
        }
        .sheet(isPresented: $vm.showCreationWizard) {
            VMCreationWizard(
                onCreate: { config in
                    viewModel.addCreatedVM(config)
                },
                onDismiss: {
                    viewModel.showCreationWizard = false
                }
            )
        }
        .sheet(isPresented: $vm.showImportSheet) {
            VMImportView(
                onImport: { config in
                    viewModel.addImportedVM(config)
                },
                onDismiss: {
                    viewModel.showImportSheet = false
                }
            )
        }
        .sheet(isPresented: $vm.showSettings) {
            if let config = viewModel.selectedConfig {
                VMSettingsView(
                    config: config,
                    isRunning: viewModel.isRunning(config.id),
                    onSave: { updated in
                        viewModel.updateVM(updated)
                        viewModel.showSettings = false
                    },
                    onDismiss: {
                        viewModel.showSettings = false
                    }
                )
            }
        }
    }
}

// MARK: - Sidebar

/// The sidebar lists all VMs with name, icon, and status LED.
private struct SidebarView: View {
    @Environment(VMLibraryViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        Group {
            if viewModel.isLoading {
                ProgressView("Loading VMs...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.configurations.isEmpty {
                EmptyLibraryView()
            } else {
                List(viewModel.configurations, selection: $vm.selectedVMID) { config in
                    VMSidebarRow(config: config)
                        .tag(config.id)
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    viewModel.showCreationWizard = true
                } label: {
                    Label("New VM", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Create a new virtual machine")

                Button {
                    viewModel.showImportSheet = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Import a disk image as a new VM")

                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reload VM list from disk")

                Spacer()

                Text("\(viewModel.configurations.count) VMs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("Vortex")
    }
}

/// Empty state shown when no VMs exist.
private struct EmptyLibraryView: View {
    @Environment(VMLibraryViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No VMs Found")
                .font(.headline)

            Text("Create a new virtual machine or import an existing disk image.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    viewModel.showCreationWizard = true
                } label: {
                    Label("Create VM", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)

                Button {
                    viewModel.showImportSheet = true
                } label: {
                    Label("Import VM", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Sidebar Row

/// A single row in the VM sidebar list.
private struct VMSidebarRow: View {
    let config: VMConfiguration
    @Environment(VMLibraryViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 10) {
            // Status LED
            Circle()
                .fill(ledColor)
                .frame(width: 8, height: 8)

            // OS icon
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            // VM name and subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(config.identity.name)
                    .font(.body)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        config.identity.iconName ?? "desktopcomputer"
    }

    private var subtitle: String {
        let os = config.guestOS.displayName
        let state = viewModel.stateLabel(for: config.id)
        return "\(os) -- \(state)"
    }

    private var ledColor: Color {
        switch viewModel.statusColor(for: config.id) {
        case .running: return .green
        case .paused:  return .yellow
        case .stopped: return .gray
        }
    }
}

// MARK: - Detail View

/// The detail pane shows selected VM info and action buttons.
private struct DetailView: View {
    @Environment(VMLibraryViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let config = viewModel.selectedConfig {
            VMDetailContent(config: config)
        } else {
            NoSelectionView()
        }
    }
}

/// Placeholder shown when no VM is selected.
private struct NoSelectionView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select a VM")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - VM Detail Content

/// Shows detailed information and controls for a selected VM.
private struct VMDetailContent: View {
    let config: VMConfiguration
    @Environment(VMLibraryViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    private var isRunning: Bool {
        viewModel.isRunning(config.id)
    }

    private var controller: VMController? {
        viewModel.controller(for: config.id)
    }

    private var usesExternalResources: Bool {
        viewModel.usesExternalResources(for: config)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header with settings and delete buttons
                headerSection
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                Divider()
                    .padding(.horizontal, 24)

                if usesExternalResources {
                    externalFilesBanner
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)

                    Divider()
                        .padding(.horizontal, 24)
                }

                // Install macOS prompt for fresh VMs
                if viewModel.needsOSInstall(for: config) {
                    installPrompt
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)

                    Divider()
                        .padding(.horizontal, 24)
                }

                // Info grid
                infoGrid
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()
                    .padding(.horizontal, 24)

                // Audio section
                audioSection
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()
                    .padding(.horizontal, 24)

                // Action buttons
                actionButtons
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                // Error banner
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(config.identity.name)
        .alert("Delete VM", isPresented: Bindable(viewModel).showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                viewModel.deleteVM(id: config.id)
            }
        } message: {
            if usesExternalResources {
                Text("Are you sure you want to delete \"\(config.identity.name)\"? This will remove the Vortex VM bundle and metadata, but leave the referenced external files in place.")
            } else {
                Text("Are you sure you want to delete \"\(config.identity.name)\"? This will permanently remove the VM and all its disk images. This action cannot be undone.")
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 16) {
            Image(systemName: config.identity.iconName ?? "desktopcomputer")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(config.identity.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 8) {
                    statusBadge

                    Text(config.guestOS.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(config.id.uuidString.prefix(8))
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Settings button
            Button {
                viewModel.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("VM Settings")

            // Delete button
            Button(role: .destructive) {
                viewModel.showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Delete VM")
            .disabled(isRunning)
        }
    }

    // MARK: - Install Prompt

    private var installPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("macOS Not Installed")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("This VM needs macOS installed before it can boot. Start the VM to begin the install process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openWindow(value: config.id)
                Task {
                    await viewModel.bootVM(id: config.id)
                }
            } label: {
                Label("Install macOS", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(14)
        .background(.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var externalFilesBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.link")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("External VM Files")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("This VM references files outside its Vortex bundle. Shut down other hypervisors first before starting it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Snapshots are disabled because the source of truth lives outside the Vortex bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusBadge: some View {
        let label = viewModel.stateLabel(for: config.id)
        let color: Color = {
            switch viewModel.statusColor(for: config.id) {
            case .running: return .green
            case .paused:  return .yellow
            case .stopped: return .gray
            }
        }()

        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: - Info Grid

    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hardware")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ], spacing: 12) {
                InfoItem(label: "CPU", value: "\(config.hardware.cpuCoreCount) cores")
                InfoItem(label: "Memory", value: config.hardware.memoryDisplayString)
                InfoItem(label: "Disk", value: diskSummary)
                InfoItem(label: "Files", value: usesExternalResources ? "External" : "Managed by Vortex")
                InfoItem(label: "Display", value: displaySummary)
                InfoItem(label: "Network", value: networkSummary)
                InfoItem(label: "Clipboard", value: config.clipboard.enabled ? "Enabled" : "Disabled")
            }
        }
    }

    private var diskSummary: String {
        guard let disk = config.storage.bootDisk else { return "None" }
        let gib = disk.sizeBytes / (1024 * 1024 * 1024)
        return "\(gib) GiB"
    }

    private var displaySummary: String {
        "\(config.display.widthPixels)x\(config.display.heightPixels)"
    }

    private var networkSummary: String {
        let count = config.network.interfaces.count
        if count == 0 { return "None" }
        let mode = config.network.interfaces.first.map { "\($0.mode)" } ?? ""
        return "\(count) interface\(count == 1 ? "" : "s") (\(mode))"
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if config.audio.enabled {
                HStack(spacing: 16) {
                    InfoItem(
                        label: "Output",
                        value: config.audio.output?.hostDeviceName ?? "System Default"
                    )
                    InfoItem(
                        label: "Input",
                        value: config.audio.input?.hostDeviceName ?? "None"
                    )
                }
            } else {
                Text("Audio is disabled for this VM.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if !isRunning {
                Button {
                    openWindow(value: config.id)
                    Task {
                        await viewModel.bootVM(id: config.id)
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if isRunning {
                Button {
                    Task { await controller?.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .disabled(controller?.vm.canPause != true)
            }

            if controller?.isPaused == true {
                Button {
                    Task { await controller?.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            }

            if isRunning || controller?.isPaused == true {
                Button(role: .destructive) {
                    Task { await viewModel.stopVM(id: config.id) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if isRunning {
                Button {
                    openWindow(value: config.id)
                } label: {
                    Label("Open Display", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer()
            Button("Dismiss") {
                viewModel.errorMessage = nil
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Info Item

/// A label/value pair used in the detail info grid.
private struct InfoItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline)
                .lineLimit(1)
        }
    }
}
