// VMImportView.swift -- Import sheet for bringing external disk images into Vortex.
// VortexGUI
//
// Presents an NSOpenPanel to select a .img disk image, auto-detects companion
// files (AuxiliaryStorage, hardwareModel.bin, machineIdentifier.bin) near the
// disk and in UTM config.plist if present, lets the user configure the VM
// (name, CPU, memory), then creates a VM bundle via VMFileManager, clones the
// disk with clonefile() + fallback, copies companions, and saves the config
// via VMRepository.

import Darwin
import Foundation
import SwiftUI
import VortexCore
import VortexPersistence

// MARK: - VMImportView

/// Sheet view for importing an existing disk image as a new Vortex VM.
struct VMImportView: View {

    /// Callback invoked when a VM is successfully imported.
    var onImport: (VMConfiguration) -> Void

    /// Callback to dismiss the sheet.
    var onDismiss: () -> Void

    // MARK: - State

    /// Path to the selected disk image file.
    @State private var diskImageURL: URL?

    /// Auto-detected companion file paths.
    @State private var auxiliaryStoragePath: URL?
    @State private var hardwareModelPath: URL?
    @State private var machineIdentifierPath: URL?

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
                .disabled(diskImageURL == nil || isImporting || vmName.trimmingCharacters(in: .whitespaces).isEmpty)
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
                    url: auxiliaryStoragePath,
                    icon: "tray.fill"
                )
                companionRow(
                    label: "hardwareModel.bin",
                    url: hardwareModelPath,
                    icon: "cpu"
                )
                companionRow(
                    label: "machineIdentifier.bin",
                    url: machineIdentifierPath,
                    icon: "number"
                )
            }
            .padding(12)
            .background(.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func companionRow(label: String, url: URL?, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(label)
                .font(.subheadline)

            Spacer()

            if let url = url {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(url.lastPathComponent)
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
        hardwareModelPath = nil
        machineIdentifierPath = nil

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
            if hardwareModelPath == nil {
                let candidate = dir.appendingPathComponent("hardwareModel.bin")
                if fm.fileExists(atPath: candidate.path) {
                    hardwareModelPath = candidate
                }
            }
            if machineIdentifierPath == nil {
                let candidate = dir.appendingPathComponent("machineIdentifier.bin")
                if fm.fileExists(atPath: candidate.path) {
                    machineIdentifierPath = candidate
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
                  let data = try? Data(contentsOf: configPlist),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) as? [String: Any] else {
                continue
            }

            // UTM stores data paths relative to the .utm bundle's Data directory.
            let dataDir = dir.appendingPathComponent("Data")

            // Try known UTM plist keys for auxiliary storage.
            if auxiliaryStoragePath == nil {
                if let relPath = extractString(from: plist, keyPath: ["Virtualization", "MacAuxiliaryStorage"]) {
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

            if hardwareModelPath == nil {
                let candidate = dataDir.appendingPathComponent("hardwareModel.bin")
                if fm.fileExists(atPath: candidate.path) {
                    hardwareModelPath = candidate
                }
            }

            if machineIdentifierPath == nil {
                let candidate = dataDir.appendingPathComponent("machineIdentifier.bin")
                if fm.fileExists(atPath: candidate.path) {
                    machineIdentifierPath = candidate
                }
                // UTM sometimes names it differently.
                let altCandidate = dataDir.appendingPathComponent("MachineIdentifier")
                if machineIdentifierPath == nil && fm.fileExists(atPath: altCandidate.path) {
                    machineIdentifierPath = altCandidate
                }
            }

            // If we found the config.plist, no need to keep searching.
            break
        }
    }

    /// Extracts a string value from a nested dictionary using a key path.
    private func extractString(from dict: [String: Any], keyPath: [String]) -> String? {
        guard !keyPath.isEmpty else { return nil }
        if keyPath.count == 1 {
            return dict[keyPath[0]] as? String
        }
        guard let nested = dict[keyPath[0]] as? [String: Any] else { return nil }
        return extractString(from: nested, keyPath: Array(keyPath.dropFirst()))
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

        // Determine if this is a macOS VM based on companion files.
        let isMacOS = auxiliaryStoragePath != nil || machineIdentifierPath != nil

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

            if let hwModelSource = hardwareModelPath {
                importProgress = "Copying hardware model..."
                let hwModelDst = fileManager.subdirectoryPath(.auxiliary, for: vmID)
                    .appendingPathComponent("hardwareModel.bin")
                try copyFile(from: hwModelSource, to: hwModelDst)
            }

            if let machineIdSource = machineIdentifierPath {
                importProgress = "Copying machine identifier..."
                try copyFile(from: machineIdSource, to: machineIdDstPath)
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
}
