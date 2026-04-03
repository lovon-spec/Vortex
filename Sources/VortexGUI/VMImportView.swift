// VMImportView.swift -- Import sheet for bringing external disk images into Vortex.
// VortexGUI
//
// Presents an NSOpenPanel to select a .img disk image, auto-detects companion
// files (AuxiliaryStorage, hardwareModel.bin, machineIdentifier.bin) near the
// disk and in UTM config.plist if present, lets the user configure the VM
// (name, CPU, memory), then creates a VM bundle via VMFileManager, clones the
// disk with clonefile() + fallback, materializes any embedded UTM macOS
// identity blobs, copies companions, and saves the config via VMRepository.

import Darwin
import Foundation
import SwiftUI
import VortexCore
import VortexPersistence

// MARK: - VMImportView

/// Sheet view for importing an existing disk image as a new Vortex VM.
struct VMImportView: View {

    /// A macOS companion can come from a sidecar file or be embedded in UTM's
    /// config.plist as raw Virtualization.framework data.
    private enum CompanionSource {
        case file(URL)
        case embedded(data: Data, source: URL)

        var displayName: String {
            switch self {
            case .file(let url):
                return url.lastPathComponent
            case .embedded(_, let source):
                return "Embedded in \(source.lastPathComponent)"
            }
        }
    }

    /// Callback invoked when a VM is successfully imported.
    var onImport: (VMConfiguration) -> Void

    /// Callback to dismiss the sheet.
    var onDismiss: () -> Void

    // MARK: - State

    /// Path to the selected disk image file.
    @State private var diskImageURL: URL?

    /// Auto-detected companion file paths and embedded macOS identity data.
    @State private var auxiliaryStoragePath: URL?
    @State private var hardwareModelSource: CompanionSource?
    @State private var machineIdentifierSource: CompanionSource?

    /// User-configurable VM parameters.
    @State private var vmName: String = "Imported VM"
    @State private var cpuCores: Int = 4
    @State private var memoryGiB: Int = 8

    /// Progress and error state.
    @State private var isImporting: Bool = false
    @State private var importProgress: String = ""
    @State private var importError: String?

    // MARK: - Constants

    private static let memoryOptions: [Int] = [2, 4, 8, 16, 32]

    private var maxCPUCores: Int {
        HardwareProfile.maximumCPUCores
    }

    private var hasAuxiliaryStorage: Bool {
        auxiliaryStoragePath != nil
    }

    private var hasHardwareModel: Bool {
        hardwareModelSource != nil
    }

    private var hasMachineIdentifier: Bool {
        machineIdentifierSource != nil
    }

    private var hasAnyMacPlatformArtifact: Bool {
        hasAuxiliaryStorage || hasHardwareModel || hasMachineIdentifier
    }

    private var hasCompleteMacPlatformArtifacts: Bool {
        hasAuxiliaryStorage && hasHardwareModel && hasMachineIdentifier
    }

    private var canImport: Bool {
        diskImageURL != nil
            && !isImporting
            && !vmName.trimmingCharacters(in: .whitespaces).isEmpty
            && (!hasAnyMacPlatformArtifact || hasCompleteMacPlatformArtifacts)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Import Virtual Machine")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Disk image selection
                    diskSelectionSection
                        .padding(.top, 16)

                    // Companion files status
                    if diskImageURL != nil {
                        companionFilesSection
                    }

                    if hasAnyMacPlatformArtifact && !hasCompleteMacPlatformArtifacts {
                        incompleteMacImportWarning
                    }

                    // VM configuration
                    if diskImageURL != nil {
                        configurationSection
                    }

                    // Progress / error
                    if isImporting {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(importProgress)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    if let error = importError {
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

            Divider()
                .padding(.horizontal, 16)

            // Action buttons
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import") {
                    Task {
                        await performImport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!canImport)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 540)
    }

    // MARK: - Disk Selection

    private var diskSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disk Image")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 12) {
                if let url = diskImageURL {
                    Image(systemName: "internaldrive.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let size = diskImageFileSize(url) {
                            Text(size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button("Change") {
                        openDiskImagePanel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)

                        Text("Select a .img disk image to import")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button("Browse...") {
                            openDiskImagePanel()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }
            .padding(12)
            .background(.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Companion Files

    private var companionFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detected Companion Files")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 6) {
                companionRow(
                    label: "AuxiliaryStorage",
                    source: auxiliaryStoragePath.map { .file($0) },
                    icon: "tray.fill"
                )
                companionRow(
                    label: "hardwareModel.bin",
                    source: hardwareModelSource,
                    icon: "cpu"
                )
                companionRow(
                    label: "machineIdentifier.bin",
                    source: machineIdentifierSource,
                    icon: "number"
                )
            }
            .padding(12)
            .background(.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var incompleteMacImportWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("This looks like a macOS VM, but Vortex needs AuxiliaryStorage, hardware model, and machine identifier to import it safely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func companionRow(label: String, source: CompanionSource?, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(label)
                .font(.subheadline)

            Spacer()

            if let source = source {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(source.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Image(systemName: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // VM Name
            VStack(alignment: .leading, spacing: 6) {
                Text("VM Name")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("VM Name", text: $vmName)
                    .textFieldStyle(.roundedBorder)
            }

            // CPU cores
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

            // Memory
            HStack {
                Label("Memory", systemImage: "memorychip")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Picker("Memory", selection: $memoryGiB) {
                    ForEach(Self.memoryOptions, id: \.self) { gib in
                        Text("\(gib) GB").tag(gib)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            .padding(12)
            .background(.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Disk Image Panel

    private func openDiskImagePanel() {
        let panel = NSOpenPanel()
        panel.title = "Select Disk Image"
        panel.message = "Choose a .img disk image file to import."
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        diskImageURL = url
        importError = nil

        // Derive a VM name from the file or parent directory.
        let stem = url.deletingPathExtension().lastPathComponent
        if stem.lowercased() != "disk" && stem.lowercased() != "boot" {
            vmName = stem
        } else {
            let parent = url.deletingLastPathComponent().lastPathComponent
            vmName = parent.replacingOccurrences(of: ".utm", with: "")
                .replacingOccurrences(of: ".vortexvm", with: "")
        }

        // Auto-detect companion files.
        detectCompanionFiles(near: url)
    }

    // MARK: - Companion File Detection

    /// Searches for macOS VM companion files near the selected disk image.
    ///
    /// Checks the disk image's directory and parent directories for:
    /// - AuxiliaryStorage (NVRAM)
    /// - hardwareModel.bin
    /// - machineIdentifier.bin
    ///
    /// Also attempts to extract paths from a UTM config.plist if one is found
    /// in a parent .utm bundle.
    private func detectCompanionFiles(near diskURL: URL) {
        auxiliaryStoragePath = nil
        hardwareModelSource = nil
        machineIdentifierSource = nil

        let fm = FileManager.default

        // Directories to search, starting from the disk's own directory.
        let diskDir = diskURL.deletingLastPathComponent()
        var searchDirs: [URL] = [diskDir]

        // Walk up to 3 levels of parent directories looking for companions or UTM bundles.
        var parent = diskDir
        for _ in 0..<3 {
            parent = parent.deletingLastPathComponent()
            if parent.path == "/" { break }
            searchDirs.append(parent)
        }

        // Search each directory for companion files.
        for dir in searchDirs {
            if auxiliaryStoragePath == nil {
                let candidate = dir.appendingPathComponent("AuxiliaryStorage")
                if fm.fileExists(atPath: candidate.path) {
                    auxiliaryStoragePath = candidate
                }
            }
            if hardwareModelSource == nil {
                let candidate = dir.appendingPathComponent("hardwareModel.bin")
                if fm.fileExists(atPath: candidate.path) {
                    hardwareModelSource = .file(candidate)
                }
            }
            if machineIdentifierSource == nil {
                let candidate = dir.appendingPathComponent("machineIdentifier.bin")
                if fm.fileExists(atPath: candidate.path) {
                    machineIdentifierSource = .file(candidate)
                }
            }
        }

        // Try extracting from UTM config.plist if present.
        extractFromUTMConfig(searchDirs: searchDirs)
    }

    /// Looks for a UTM config.plist in the given directories and attempts to
    /// resolve companion file paths from its contents.
    private func extractFromUTMConfig(searchDirs: [URL]) {
        let fm = FileManager.default

        for dir in searchDirs {
            let configPlist = dir.appendingPathComponent("config.plist")
            guard fm.fileExists(atPath: configPlist.path),
                  let plist = try? UTMConfigPlist.load(from: configPlist) else {
                continue
            }

            // UTM stores data paths relative to the .utm bundle's Data directory.
            let dataDir = dir.appendingPathComponent("Data")

            // Try known UTM plist keys for auxiliary storage.
            if auxiliaryStoragePath == nil {
                if let relPath = plist.auxiliaryStorageRelativePath {
                    let candidate = dataDir.appendingPathComponent(relPath)
                    if fm.fileExists(atPath: candidate.path) {
                        auxiliaryStoragePath = candidate
                    }
                }
                // Also try raw file name in Data directory.
                let candidate = dataDir.appendingPathComponent("AuxiliaryStorage")
                if auxiliaryStoragePath == nil && fm.fileExists(atPath: candidate.path) {
                    auxiliaryStoragePath = candidate
                }
            }

            if hardwareModelSource == nil,
               let hardwareModelData = plist.embeddedHardwareModelData {
                hardwareModelSource = .embedded(data: hardwareModelData, source: configPlist)
            }

            if hardwareModelSource == nil {
                let candidate = dataDir.appendingPathComponent("hardwareModel.bin")
                if fm.fileExists(atPath: candidate.path) {
                    hardwareModelSource = .file(candidate)
                }
            }

            if machineIdentifierSource == nil,
               let machineIdentifierData = plist.embeddedMachineIdentifierData {
                machineIdentifierSource = .embedded(data: machineIdentifierData, source: configPlist)
            }

            if machineIdentifierSource == nil {
                let candidate = dataDir.appendingPathComponent("machineIdentifier.bin")
                if fm.fileExists(atPath: candidate.path) {
                    machineIdentifierSource = .file(candidate)
                }
                // UTM sometimes names it differently.
                let altCandidate = dataDir.appendingPathComponent("MachineIdentifier")
                if machineIdentifierSource == nil && fm.fileExists(atPath: altCandidate.path) {
                    machineIdentifierSource = .file(altCandidate)
                }
            }

            // If we found the config.plist, no need to keep searching.
            break
        }
    }

    // MARK: - File Size Display

    private func diskImageFileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? UInt64 else {
            return nil
        }
        let gib = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gib >= 1.0 {
            return String(format: "%.1f GiB on disk", gib)
        }
        let mib = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MiB on disk", mib)
    }

    // MARK: - Import

    /// Performs the full import: creates the VM bundle, clones the disk image,
    /// copies companion files, and saves the configuration.
    private func performImport() async {
        guard let sourceURL = diskImageURL else { return }

        isImporting = true
        importError = nil
        importProgress = "Preparing..."

        let fileManager = VMFileManager()
        let repo = VMRepository(fileManager: fileManager)

        let vmID = UUID()
        let trimmedName = vmName.trimmingCharacters(in: .whitespaces)

        // Build the VM configuration.
        let diskPath = fileManager.diskPath(vmID: vmID, diskName: "boot.img")
        let auxDstPath = fileManager.subdirectoryPath(.auxiliary, for: vmID)
            .appendingPathComponent("AuxiliaryStorage")
        let machineIdDstPath = fileManager.subdirectoryPath(.auxiliary, for: vmID)
            .appendingPathComponent("machineIdentifier.bin")

        // Determine disk size from the source file.
        let diskSizeBytes: UInt64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
           let size = attrs[.size] as? UInt64, size > 0 {
            diskSizeBytes = size
        } else {
            // Default to 64 GiB if we cannot determine the size.
            diskSizeBytes = 64 * 1024 * 1024 * 1024
        }

        if hasAnyMacPlatformArtifact && !hasCompleteMacPlatformArtifacts {
            importError = "Import failed: incomplete macOS identity. Vortex needs AuxiliaryStorage, hardware model, and machine identifier for a bootable macOS import."
            isImporting = false
            return
        }

        // Determine if this is a macOS VM based on companion files.
        let isMacOS = hasCompleteMacPlatformArtifacts

        let config: VMConfiguration
        if isMacOS {
            config = VMConfiguration(
                id: vmID,
                identity: VMIdentity(name: trimmedName, iconName: "desktopcomputer"),
                guestOS: .macOS,
                hardware: HardwareProfile(cpuCoreCount: cpuCores, memoryGiB: UInt64(memoryGiB)),
                storage: StorageConfiguration(disks: [
                    DiskConfig(
                        label: "Boot Disk",
                        imagePath: diskPath.path,
                        sizeBytes: diskSizeBytes
                    )
                ]),
                network: .singleNAT,
                display: .standard,
                audio: .systemDefaults,
                clipboard: .enabled,
                bootConfig: .macOS(
                    auxiliaryStoragePath: auxDstPath.path,
                    machineIdentifierPath: machineIdDstPath.path
                )
            )
        } else {
            let efiStorePath = fileManager.subdirectoryPath(.efi, for: vmID)
                .appendingPathComponent("efi_vars.fd")
            config = VMConfiguration(
                id: vmID,
                identity: VMIdentity(name: trimmedName, iconName: "pc"),
                guestOS: .linuxARM64,
                hardware: HardwareProfile(cpuCoreCount: cpuCores, memoryGiB: UInt64(memoryGiB)),
                storage: StorageConfiguration(disks: [
                    DiskConfig(
                        label: "Boot Disk",
                        imagePath: diskPath.path,
                        sizeBytes: diskSizeBytes
                    )
                ]),
                network: .singleNAT,
                display: .standard,
                audio: .systemDefaults,
                clipboard: .disabled,
                bootConfig: .uefi(storePath: efiStorePath.path)
            )
        }

        do {
            // Step 1: Create the VM bundle directory structure.
            importProgress = "Creating VM bundle..."
            try fileManager.ensureBaseDirectoryExists()
            try fileManager.createVMBundle(for: config)

            // Step 2: Clone the disk image.
            importProgress = "Copying disk image..."
            try cloneFile(from: sourceURL, to: diskPath)

            // Step 3: Copy companion files.
            if let auxSource = auxiliaryStoragePath {
                importProgress = "Copying auxiliary storage..."
                try copyFile(from: auxSource, to: auxDstPath)
            }

            if let hwModelSource = hardwareModelSource {
                importProgress = "Copying hardware model..."
                let hwModelDst = fileManager.subdirectoryPath(.auxiliary, for: vmID)
                    .appendingPathComponent("hardwareModel.bin")
                try persistCompanion(from: hwModelSource, to: hwModelDst)
            }

            if let machineIdSource = machineIdentifierSource {
                importProgress = "Copying machine identifier..."
                try persistCompanion(from: machineIdSource, to: machineIdDstPath)
            }

            // Step 4: Save the configuration.
            importProgress = "Saving configuration..."
            try repo.save(config)

            VortexLog.gui.info("VM imported: \(config.identity.name) (\(config.id))")

            isImporting = false
            onImport(config)
        } catch {
            VortexLog.gui.error("VM import failed: \(error.localizedDescription)")
            importError = "Import failed: \(error.localizedDescription)"
            isImporting = false

            // Clean up partial bundle on failure.
            try? fileManager.deleteVMBundle(id: vmID)
        }
    }

    // MARK: - File Operations

    /// Clones a file using Darwin.clonefile(), falling back to
    /// FileManager.copyItem when clonefile is unsupported (ENOTSUP) or the
    /// source and destination are on different volumes (EXDEV).
    private func cloneFile(from source: URL, to destination: URL) throws {
        // Ensure parent directory exists.
        let parentDir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let result = Darwin.clonefile(source.path, destination.path, 0)
        if result == 0 {
            VortexLog.gui.debug("Disk image cloned via clonefile()")
            return
        }

        let cloneErrno = errno
        if cloneErrno == ENOTSUP || cloneErrno == EXDEV {
            // Fallback: full byte copy for cross-volume or non-APFS.
            VortexLog.gui.info("clonefile() returned errno \(cloneErrno), falling back to copy")
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw VortexError.diskOperationFailed(
                    reason: "Failed to copy disk image from \(source.path) to \(destination.path): \(error.localizedDescription)"
                )
            }
        } else {
            throw VortexError.diskOperationFailed(
                reason: "clonefile() failed for \(source.lastPathComponent): errno \(cloneErrno)"
            )
        }
    }

    /// Copies a single file from source to destination.
    private func copyFile(from source: URL, to destination: URL) throws {
        let parentDir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw VortexError.diskOperationFailed(
                reason: "Failed to copy \(source.lastPathComponent) to \(destination.path): \(error.localizedDescription)"
            )
        }
    }

    /// Persists a companion artifact to the destination, whether it comes from
    /// a sidecar file or embedded UTM plist data.
    private func persistCompanion(from source: CompanionSource, to destination: URL) throws {
        switch source {
        case .file(let url):
            try copyFile(from: url, to: destination)
        case .embedded(let data, _):
            try writeData(data, to: destination)
        }
    }

    /// Writes raw data to a single file destination.
    private func writeData(_ data: Data, to destination: URL) throws {
        let parentDir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw VortexError.diskOperationFailed(
                reason: "Failed to write \(destination.lastPathComponent) to \(destination.path): \(error.localizedDescription)"
            )
        }
    }
}
