// VMCreationWizard.swift -- Multi-step VM creation wizard sheet.
// VortexGUI
//
// A four-step wizard presented as a sheet from the library view:
// 1. Choose OS (macOS / Linux ARM64 / Windows ARM)
// 2. Configure hardware (CPU, memory, disk, display)
// 3. Configure audio (output/input device selection)
// 4. Review and create
//
// On creation, the wizard calls VMFileManager to create the bundle and disk
// image, then VMRepository to persist the configuration.

import os
import SwiftUI
import VortexAudio
import VortexCore
import VortexPersistence

// MARK: - Wizard Step

/// The four sequential steps of the VM creation wizard.
enum WizardStep: Int, CaseIterable {
    case os = 0
    case hardware = 1
    case audio = 2
    case review = 3

    var title: String {
        switch self {
        case .os:       return "Operating System"
        case .hardware: return "Hardware"
        case .audio:    return "Audio"
        case .review:   return "Review & Create"
        }
    }
}

// MARK: - VMCreationWizard

/// Multi-step sheet for creating a new VM from the library view.
struct VMCreationWizard: View {

    /// Callback invoked when a VM is successfully created, passing the new config.
    var onCreate: (VMConfiguration) -> Void

    /// Callback to dismiss the sheet.
    var onDismiss: () -> Void

    // MARK: - State

    @State private var currentStep: WizardStep = .os

    // Step 1: OS selection
    @State private var selectedOS: GuestOS = .macOS

    // Step 2: Hardware
    @State private var cpuCores: Int = 4
    @State private var memoryGiB: Int = min(8, HardwareProfile.maximumMemoryGiB)
    @State private var diskSizeGiB: Int = 64
    @State private var displayPreset: DisplayPreset = .fhd

    // Step 3: Audio
    @State private var outputDevices: [AudioHostDevice] = []
    @State private var inputDevices: [AudioHostDevice] = []
    @State private var selectedOutputUID: String = noneUID
    @State private var selectedInputUID: String = noneUID

    // Step 4: Review
    @State private var vmName: String = ""
    @State private var isCreating: Bool = false
    @State private var creationProgress: String = ""
    @State private var creationError: String?

    /// Sentinel UID representing "None" (disabled).
    private static let noneUID = "__none__"

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 16)

            // Step content
            Group {
                switch currentStep {
                case .os:       osStep
                case .hardware: hardwareStep
                case .audio:    audioStep
                case .review:   reviewStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 16)

            // Navigation buttons
            navigationButtons
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            generateDefaultName()
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(WizardStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(step.rawValue <= currentStep.rawValue ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: 24, height: 24)

                        if step.rawValue < currentStep.rawValue {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(step.rawValue <= currentStep.rawValue ? .white : .secondary)
                        }
                    }

                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                        .lineLimit(1)
                }

                if step != WizardStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue ? Color.blue : Color.gray.opacity(0.3))
                        .frame(height: 1)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    // MARK: - Step 1: OS Selection

    private var osStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Operating System")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 24)
                .padding(.top, 20)

            Text("Select the guest OS you want to install in this virtual machine.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            HStack(spacing: 16) {
                OSCard(
                    os: .macOS,
                    icon: "desktopcomputer",
                    title: "macOS",
                    subtitle: "Apple Silicon native",
                    isSelected: selectedOS == .macOS
                ) {
                    selectedOS = .macOS
                    applyOSDefaults()
                }

                OSCard(
                    os: .linuxARM64,
                    icon: "pc",
                    title: "Linux (ARM64)",
                    subtitle: "UEFI boot, VirtIO",
                    isSelected: selectedOS == .linuxARM64
                ) {
                    selectedOS = .linuxARM64
                    applyOSDefaults()
                }

                OSCard(
                    os: .windowsARM,
                    icon: "rectangle.on.rectangle.badge.gearshape",
                    title: "Windows (ARM)",
                    subtitle: "UEFI boot",
                    isSelected: selectedOS == .windowsARM
                ) {
                    selectedOS = .windowsARM
                    applyOSDefaults()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Step 2: Hardware

    private var hardwareStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Configure Hardware")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.top, 20)

                // CPU cores
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("CPU Cores", systemImage: "cpu")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Stepper("\(cpuCores) cores", value: $cpuCores, in: 1...maxCPUCores)
                            .frame(width: 160)
                    }
                    .padding(12)
                    .background(.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Memory
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Memory", systemImage: "memorychip")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Stepper(
                            "\(memoryGiB) GB",
                            value: $memoryGiB,
                            in: minMemoryGiB...maxMemoryGiB
                        )
                        .frame(width: 160)
                    }
                    .padding(12)
                    .background(.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Disk size
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Disk Size", systemImage: "internaldrive")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Stepper("\(diskSizeGiB) GB", value: $diskSizeGiB, in: 16...256, step: 16)
                            .frame(width: 160)
                    }
                    .padding(12)
                    .background(.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Display
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Display", systemImage: "display")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Picker("Display", selection: $displayPreset) {
                            ForEach(DisplayPreset.allCases, id: \.self) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    .padding(12)
                    .background(.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Step 3: Audio

    private var audioStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Configuration")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 24)
                .padding(.top, 20)

            Text("Choose which host audio devices to route to this VM.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 16) {
                // Output device
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Output Device")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }

                    Picker("Output", selection: $selectedOutputUID) {
                        Text("None (disabled)").tag(Self.noneUID)
                        if !outputDevices.isEmpty {
                            Divider()
                        }
                        ForEach(outputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Input device
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Input Device")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }

                    Picker("Input", selection: $selectedInputUID) {
                        Text("None (disabled)").tag(Self.noneUID)
                        if !inputDevices.isEmpty {
                            Divider()
                        }
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)

            Spacer()
        }
        .onAppear {
            refreshAudioDevices()
        }
    }

    // MARK: - Step 4: Review

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review & Create")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.top, 20)

                // VM name
                VStack(alignment: .leading, spacing: 6) {
                    Text("VM Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField("VM Name", text: $vmName)
                        .textFieldStyle(.roundedBorder)
                }

                // Summary grid
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configuration Summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading),
                    ], spacing: 10) {
                        SummaryItem(label: "OS", value: selectedOS.displayName)
                        SummaryItem(label: "CPU", value: "\(cpuCores) cores")
                        SummaryItem(label: "Memory", value: "\(memoryGiB) GB")
                        SummaryItem(label: "Disk", value: "\(diskSizeGiB) GB")
                        SummaryItem(label: "Display", value: displayPreset.label)
                        SummaryItem(label: "Audio Output", value: audioOutputName)
                        SummaryItem(label: "Audio Input", value: audioInputName)
                        SummaryItem(label: "Network", value: "NAT")
                    }
                }
                .padding(12)
                .background(.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Creation progress
                if isCreating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(creationProgress)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                // Creation error
                if let error = creationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if currentStep != .os {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        goBack()
                    }
                }
            }

            if currentStep == .review {
                Button("Create") {
                    Task {
                        await createVM()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isCreating || vmName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        goNext()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Navigation

    private func goNext() {
        guard let nextIndex = WizardStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextIndex
    }

    private func goBack() {
        guard let prevIndex = WizardStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevIndex
    }

    // MARK: - Display Presets

    enum DisplayPreset: String, CaseIterable {
        case fhd = "fhd"
        case qhd = "qhd"
        case retina = "retina"

        var label: String {
            switch self {
            case .fhd:    return "1920 x 1080"
            case .qhd:    return "2560 x 1440"
            case .retina: return "3024 x 1964 Retina"
            }
        }

        var config: DisplayConfiguration {
            switch self {
            case .fhd:
                return DisplayConfiguration(widthPixels: 1920, heightPixels: 1080, pixelsPerInch: 96)
            case .qhd:
                return DisplayConfiguration(widthPixels: 2560, heightPixels: 1440, pixelsPerInch: 109)
            case .retina:
                return DisplayConfiguration(widthPixels: 3024, heightPixels: 1964, pixelsPerInch: 218)
            }
        }
    }

    // MARK: - Computed

    private var maxCPUCores: Int {
        HardwareProfile.maximumCPUCores
    }

    private var minMemoryGiB: Int {
        HardwareProfile.minimumMemoryGiB
    }

    private var maxMemoryGiB: Int {
        HardwareProfile.maximumMemoryGiB
    }

    private func clampedMemoryGiB(_ desired: Int) -> Int {
        min(max(desired, minMemoryGiB), maxMemoryGiB)
    }

    private var audioOutputName: String {
        if selectedOutputUID == Self.noneUID { return "None" }
        return outputDevices.first(where: { $0.uid == selectedOutputUID })?.name ?? "None"
    }

    private var audioInputName: String {
        if selectedInputUID == Self.noneUID { return "None" }
        return inputDevices.first(where: { $0.uid == selectedInputUID })?.name ?? "None"
    }

    // MARK: - Defaults

    private func generateDefaultName() {
        vmName = "\(selectedOS.displayName) VM"
    }

    private func applyOSDefaults() {
        switch selectedOS {
        case .macOS:
            cpuCores = 4
            memoryGiB = clampedMemoryGiB(8)
            diskSizeGiB = 64
        case .linuxARM64:
            cpuCores = 4
            memoryGiB = clampedMemoryGiB(4)
            diskSizeGiB = 32
        case .windowsARM:
            cpuCores = 4
            memoryGiB = clampedMemoryGiB(8)
            diskSizeGiB = 64
        }
        generateDefaultName()
    }

    // MARK: - Audio Devices

    private func refreshAudioDevices() {
        let enumerator = AudioDeviceEnumerator()
        do {
            let all = try enumerator.allDevices()
            outputDevices = all.filter(\.isOutput)
            inputDevices = all.filter(\.isInput)
        } catch {
            VortexLog.gui.error("Failed to enumerate audio devices: \(error.localizedDescription)")
            outputDevices = []
            inputDevices = []
        }
    }

    // MARK: - VM Creation

    private func createVM() async {
        isCreating = true
        creationError = nil
        creationProgress = "Preparing..."

        let fileManager = VMFileManager()
        let repo = VMRepository(fileManager: fileManager)
        let templateRepo = TemplateRepository()

        // Find the right template for the selected OS.
        let template: VMTemplate
        switch selectedOS {
        case .macOS:      template = .macOSSequoia
        case .linuxARM64: template = .ubuntu2404
        case .windowsARM: template = .windows11ARM
        }

        // Create base config from template, then customize.
        var config = templateRepo.createVM(
            from: template,
            name: vmName.trimmingCharacters(in: .whitespaces),
            fileManager: fileManager
        )

        // Apply wizard hardware selections.
        config.hardware = HardwareProfile(cpuCoreCount: cpuCores, memoryGiB: UInt64(memoryGiB))
        config.display = displayPreset.config

        // Update disk size in the storage config.
        let diskPath = fileManager.diskPath(vmID: config.id, diskName: "boot.img").path
        config.storage = StorageConfiguration(disks: [
            .bootDisk(imagePath: diskPath, sizeGiB: UInt64(diskSizeGiB))
        ])

        // Apply audio selections.
        var audioConfig = AudioConfig(enabled: true)
        if selectedOutputUID != Self.noneUID,
           let device = outputDevices.first(where: { $0.uid == selectedOutputUID }) {
            audioConfig.output = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
        }
        if selectedInputUID != Self.noneUID,
           let device = inputDevices.first(where: { $0.uid == selectedInputUID }) {
            audioConfig.input = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
        }
        if selectedOutputUID == Self.noneUID && selectedInputUID == Self.noneUID {
            audioConfig.enabled = false
        }
        config.audio = audioConfig

        // Create the bundle on disk.
        do {
            creationProgress = "Creating VM bundle..."
            try fileManager.ensureBaseDirectoryExists()
            try fileManager.createVMBundle(for: config)

            creationProgress = "Creating disk image..."
            let diskURL = fileManager.diskPath(vmID: config.id, diskName: "boot.img")
            let diskSizeBytes = UInt64(diskSizeGiB) * 1024 * 1024 * 1024
            try fileManager.createDiskImage(at: diskURL, sizeInBytes: diskSizeBytes)

            creationProgress = "Saving configuration..."
            try repo.save(config)

            VortexLog.gui.info("VM created: \(config.identity.name) (\(config.id))")

            isCreating = false
            onCreate(config)
        } catch {
            VortexLog.gui.error("VM creation failed: \(error.localizedDescription)")
            creationError = "Failed to create VM: \(error.localizedDescription)"
            isCreating = false
        }
    }
}

// MARK: - OS Selection Card

/// A selectable card representing a guest OS option.
private struct OSCard: View {
    let os: GuestOS
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(height: 40)

                VStack(spacing: 3) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(isSelected ? Color.blue.opacity(0.12) : Color.black.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Summary Item

/// A label/value pair used in the review step summary grid.
private struct SummaryItem: View {
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
