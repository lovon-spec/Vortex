// VMLibraryViewModel.swift -- Central state for the VM library and running VMs.
// VortexService
//
// Owns the list of VMConfiguration objects loaded from disk, tracks which VMs
// are currently running (each with a VMController), and provides methods to
// boot, stop, and manage VMs from the library.

import Foundation
import Observation
import Virtualization
import VortexAudio
import VortexCore
import VortexPersistence
import VortexVZ

// MARK: - VMLibraryViewModel

public enum VortexServiceError: LocalizedError {
    case outputDeviceNotFound(String, available: [String])
    case inputDeviceNotFound(String, available: [String])
    case audioDeviceEnumerationFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .outputDeviceNotFound(let name, let available):
            let list = available.isEmpty ? "No output devices are available." : available.joined(separator: ", ")
            return "Output audio device '\(name)' was not found. Available output devices: \(list)"
        case .inputDeviceNotFound(let name, let available):
            let list = available.isEmpty ? "No input devices are available." : available.joined(separator: ", ")
            return "Input audio device '\(name)' was not found. Available input devices: \(list)"
        case .audioDeviceEnumerationFailed(let error):
            return "Failed to enumerate host audio devices: \(error.localizedDescription)"
        }
    }
}

/// Single source of truth for the VM library and all running VM controllers.
///
/// The library view model:
/// - Loads all VM configs from disk on launch
/// - Creates and tracks VMController instances for running VMs
/// - Provides the selection state for the sidebar
/// - Opens VM display windows by publishing UUIDs
/// - Creates, deletes, and updates VM configurations
@MainActor
@Observable
public final class VMLibraryViewModel {

    // MARK: - Published state

    /// All VM configurations loaded from disk.
    public var configurations: [VMConfiguration] = []

    /// Currently selected VM ID in the sidebar.
    public var selectedVMID: UUID?

    /// Maps VM ID to its running controller. Only populated while a VM is running.
    public var runningControllers: [UUID: VMController] = [:]

    /// VM IDs with an active boot request. Used to collapse duplicate GUI,
    /// service, and toolbar starts into the same lifecycle operation.
    private var bootingVMIDs: Set<UUID> = []

    /// Error message to display in the library view.
    public var errorMessage: String?

    /// True while the initial load is in progress.
    public var isLoading: Bool = true

    /// Set of VM IDs that have open display windows.
    public var openDisplayWindows: Set<UUID> = []

    /// Whether to show the VM creation wizard sheet.
    public var showCreationWizard: Bool = false

    /// Whether to show the VM import sheet.
    public var showImportSheet: Bool = false

    /// Whether to show the VM settings sheet.
    public var showSettings: Bool = false

    /// Whether to show the delete confirmation alert.
    public var showDeleteConfirmation: Bool = false

    // MARK: - Dependencies

    private let repo = VMRepository()
    private let fileManager = VMFileManager()
    private let manager = VZVMManager()

    // MARK: - Computed

    /// The currently selected configuration, if any.
    public init() {}

    public var selectedConfig: VMConfiguration? {
        guard let id = selectedVMID else { return nil }
        return configurations.first(where: { $0.id == id })
    }

    /// Whether a given VM is currently running.
    public func isRunning(_ id: UUID) -> Bool {
        runningControllers[id] != nil
    }

    /// Returns the controller for a running VM, if it exists.
    public func controller(for id: UUID) -> VMController? {
        runningControllers[id]
    }

    // MARK: - Load

    /// Loads all VM configurations from disk.
    public func loadConfigurations() {
        isLoading = true
        errorMessage = nil
        do {
            configurations = try repo.loadAll()
        } catch {
            errorMessage = "Failed to load VMs: \(error.localizedDescription)"
            configurations = []
        }
        isLoading = false
    }

    /// Reloads the configuration list from disk.
    public func refresh() {
        loadConfigurations()
    }

    // MARK: - VM Lifecycle

    /// Creates a VM from the given configuration and prepares a controller.
    /// Returns the controller but does NOT start the VM yet -- the display
    /// window should call start() after it appears.
    public func prepareVM(
        id: UUID,
        startOptions: VortexVMStartOptions? = nil
    ) throws -> VMController {
        // If already running, return existing controller.
        if let existing = runningControllers[id] {
            if startOptions?.hasOverrides == true {
                VortexLog.service.warning("Ignoring start options for already running VM \(id)")
            }
            return existing
        }

        var config = try repo.load(id: id)
        if let startOptions {
            config = try applying(startOptions: startOptions, to: config)
        }

        let ownerLock = try VMOwnerLock.acquire(vmID: id, fileManager: fileManager)
        let vm: VZVirtualMachine
        do {
            vm = try manager.createVM(config: config)
        } catch {
            VmnetNetworkRegistry.shared.releaseNetworks(for: config.network.interfaces)
            ownerLock.release()
            throw error
        }

        let controller = VMController(
            vm: vm,
            manager: manager,
            config: config,
            ownerLock: ownerLock
        )
        runningControllers[id] = controller
        return controller
    }

    /// Boots a VM: creates it, registers the controller, and starts execution.
    public func bootVM(id: UUID, startOptions: VortexVMStartOptions? = nil) async {
        guard !bootingVMIDs.contains(id) else {
            VortexLog.service.debug("Ignoring duplicate boot request for VM \(id)")
            return
        }
        bootingVMIDs.insert(id)
        defer {
            bootingVMIDs.remove(id)
        }

        do {
            let controller = try prepareVM(id: id, startOptions: startOptions)
            try await Task.sleep(for: .milliseconds(200))
            await controller.start()
            if controller.errorMessage != nil
                && controller.canStart
                && !controller.isRunning
                && !controller.isPaused
                && !controller.isStarting {
                controller.releaseOwnerLock()
                runningControllers.removeValue(forKey: id)
            }
        } catch {
            errorMessage = "Failed to boot VM: \(error.localizedDescription)"
        }
    }

    /// Stops a running VM and removes its controller.
    public func stopVM(id: UUID) async {
        guard let controller = runningControllers[id] else { return }
        await controller.stop()
        controller.releaseOwnerLock()
        runningControllers.removeValue(forKey: id)
    }

    /// Removes the controller for a VM that has already stopped.
    public func cleanupController(for id: UUID) {
        runningControllers[id]?.releaseOwnerLock()
        runningControllers.removeValue(forKey: id)
    }

    // MARK: - VM Status

    /// Returns the runtime state label for a VM.
    public func stateLabel(for id: UUID) -> String {
        if let controller = runningControllers[id] {
            return controller.stateLabel
        }
        return "Stopped"
    }

    /// Returns a status color name for a VM (green=running, yellow=paused, gray=stopped).
    public func statusColor(for id: UUID) -> StatusLED {
        guard let controller = runningControllers[id] else {
            return .stopped
        }
        if controller.isRunning { return .running }
        if controller.isPaused { return .paused }
        return .stopped
    }

    /// Status LED states for the sidebar.
    public enum StatusLED {
        case running
        case paused
        case stopped
    }

    // MARK: - Create

    /// Adds a newly created VM configuration to the library and selects it.
    ///
    /// The configuration and its on-disk bundle are assumed to already exist
    /// (created by the wizard). This method refreshes the in-memory list.
    public func addCreatedVM(_ config: VMConfiguration) {
        loadConfigurations()
        selectedVMID = config.id
        showCreationWizard = false
        VortexLog.service.info("VM added to library: \(config.identity.name)")
    }

    /// Adds an imported VM configuration to the library and selects it.
    ///
    /// The configuration and its on-disk bundle are assumed to already exist
    /// (created by the import sheet). This method refreshes the in-memory list.
    public func addImportedVM(_ config: VMConfiguration) {
        loadConfigurations()
        selectedVMID = config.id
        showImportSheet = false
        VortexLog.service.info("VM imported to library: \(config.identity.name)")
    }

    // MARK: - Delete

    /// Deletes a VM's bundle and removes it from the library.
    ///
    /// The VM must be stopped before deletion. If it is running, the error
    /// message is set and the VM is not deleted.
    public func deleteVM(id: UUID) {
        guard !isRunning(id) else {
            errorMessage = "Cannot delete a running VM. Stop it first."
            return
        }

        do {
            try repo.delete(id: id)
            configurations.removeAll { $0.id == id }
            if selectedVMID == id {
                selectedVMID = configurations.first?.id
            }
            VortexLog.service.info("VM deleted: \(id)")
        } catch {
            errorMessage = "Failed to delete VM: \(error.localizedDescription)"
            VortexLog.service.error("VM deletion failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Update

    /// Persists an updated configuration and refreshes the in-memory list.
    public func updateVM(_ config: VMConfiguration) {
        do {
            try repo.update(config)
            // Replace in the local list.
            if let index = configurations.firstIndex(where: { $0.id == config.id }) {
                configurations[index] = config.touchingModifiedDate()
            }
            VortexLog.service.info("VM updated: \(config.identity.name)")
        } catch {
            errorMessage = "Failed to update VM: \(error.localizedDescription)"
            VortexLog.service.error("VM update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - OS Install Check

    /// Returns true if a macOS VM needs an OS install (disk is empty/sparse).
    public func needsOSInstall(for config: VMConfiguration) -> Bool {
        guard config.guestOS == .macOS else { return false }
        guard let disk = config.storage.bootDisk else { return true }

        // Check if the disk image file has any real content.
        // A newly created sparse disk has zero physical bytes allocated.
        let diskURL = URL(fileURLWithPath: disk.imagePath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: diskURL.path),
              let fileSize = attrs[.size] as? UInt64 else {
            return true
        }
        // A sparse file reports its logical size, but the physical allocation
        // is near zero. Use a threshold: if less than 1 MiB, treat as empty.
        return fileSize < 1024 * 1024
    }

    /// Returns true when the VM references files outside its own bundle.
    public func usesExternalResources(for config: VMConfiguration) -> Bool {
        config.usesExternalResources(bundlePath: fileManager.vmBundlePath(for: config.id))
    }

    private func applying(
        startOptions: VortexVMStartOptions,
        to config: VMConfiguration
    ) throws -> VMConfiguration {
        var updated = config
        if let audioOverride = startOptions.audioOverride {
            updated.audio = try resolveAudioOverride(audioOverride)
        }
        return updated
    }

    private func resolveAudioOverride(_ override: VortexAudioOverride) throws -> AudioConfig {
        if override.disableAudio {
            return .disabled
        }

        guard override.outputDeviceName != nil || override.inputDeviceName != nil else {
            return .systemDefaults
        }

        let enumerator = AudioDeviceEnumerator()
        let devices: [AudioHostDevice]
        do {
            devices = try enumerator.allDevices()
        } catch {
            throw VortexServiceError.audioDeviceEnumerationFailed(error)
        }

        var outputEndpoint: AudioEndpointConfig?
        var inputEndpoint: AudioEndpointConfig?

        if let outputName = override.outputDeviceName {
            guard let device = devices.first(where: { $0.name == outputName && $0.isOutput }) else {
                let available = devices
                    .filter(\.isOutput)
                    .map(\.name)
                    .sorted()
                throw VortexServiceError.outputDeviceNotFound(outputName, available: available)
            }
            outputEndpoint = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
        }

        if let inputName = override.inputDeviceName {
            guard let device = devices.first(where: { $0.name == inputName && $0.isInput }) else {
                let available = devices
                    .filter(\.isInput)
                    .map(\.name)
                    .sorted()
                throw VortexServiceError.inputDeviceNotFound(inputName, available: available)
            }
            inputEndpoint = AudioEndpointConfig(
                hostDeviceUID: device.uid,
                hostDeviceName: device.name
            )
        }

        return AudioConfig(
            enabled: true,
            output: outputEndpoint,
            input: inputEndpoint
        )
    }
}
