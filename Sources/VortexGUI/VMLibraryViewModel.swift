// VMLibraryViewModel.swift -- Central state for the VM library and running VMs.
// VortexGUI
//
// Owns the list of VMConfiguration objects loaded from disk, tracks which VMs
// are currently running (each with a VMController), and provides methods to
// boot, stop, and manage VMs from the library.

import Foundation
import Virtualization
import VortexCore
import VortexPersistence
import VortexVZ

// MARK: - VMLibraryViewModel

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
final class VMLibraryViewModel {

    // MARK: - Published state

    /// All VM configurations loaded from disk.
    var configurations: [VMConfiguration] = []

    /// Currently selected VM ID in the sidebar.
    var selectedVMID: UUID?

    /// Maps VM ID to its running controller. Only populated while a VM is running.
    var runningControllers: [UUID: VMController] = [:]

    /// Error message to display in the library view.
    var errorMessage: String?

    /// True while the initial load is in progress.
    var isLoading: Bool = true

    /// Set of VM IDs that have open display windows.
    var openDisplayWindows: Set<UUID> = []

    /// Whether to show the VM creation wizard sheet.
    var showCreationWizard: Bool = false

    /// Whether to show the VM import sheet.
    var showImportSheet: Bool = false

    /// Whether to show the VM settings sheet.
    var showSettings: Bool = false

    /// Whether to show the delete confirmation alert.
    var showDeleteConfirmation: Bool = false

    // MARK: - Dependencies

    private let repo = VMRepository()
    private let fileManager = VMFileManager()
    private let manager = VZVMManager()

    // MARK: - Computed

    /// The currently selected configuration, if any.
    var selectedConfig: VMConfiguration? {
        guard let id = selectedVMID else { return nil }
        return configurations.first(where: { $0.id == id })
    }

    /// Whether a given VM is currently running.
    func isRunning(_ id: UUID) -> Bool {
        runningControllers[id] != nil
    }

    /// Returns the controller for a running VM, if it exists.
    func controller(for id: UUID) -> VMController? {
        runningControllers[id]
    }

    // MARK: - Load

    /// Loads all VM configurations from disk.
    func loadConfigurations() {
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
    func refresh() {
        loadConfigurations()
    }

    // MARK: - VM Lifecycle

    /// Creates a VM from the given configuration and prepares a controller.
    /// Returns the controller but does NOT start the VM yet -- the display
    /// window should call start() after it appears.
    func prepareVM(id: UUID) throws -> VMController {
        // If already running, return existing controller.
        if let existing = runningControllers[id] {
            return existing
        }

        let config = try repo.load(id: id)
        let vm = try manager.createVM(config: config)
        let controller = VMController(
            vm: vm,
            manager: manager,
            config: config
        )
        runningControllers[id] = controller
        return controller
    }

    /// Boots a VM: creates it, registers the controller, and starts execution.
    func bootVM(id: UUID) async {
        do {
            let controller = try prepareVM(id: id)
            try await Task.sleep(for: .milliseconds(200))
            await controller.start()
        } catch {
            errorMessage = "Failed to boot VM: \(error.localizedDescription)"
        }
    }

    /// Stops a running VM and removes its controller.
    func stopVM(id: UUID) async {
        guard let controller = runningControllers[id] else { return }
        await controller.stop()
        runningControllers.removeValue(forKey: id)
    }

    /// Removes the controller for a VM that has already stopped.
    func cleanupController(for id: UUID) {
        runningControllers.removeValue(forKey: id)
    }

    // MARK: - VM Status

    /// Returns the runtime state label for a VM.
    func stateLabel(for id: UUID) -> String {
        if let controller = runningControllers[id] {
            return controller.stateLabel
        }
        return "Stopped"
    }

    /// Returns a status color name for a VM (green=running, yellow=paused, gray=stopped).
    func statusColor(for id: UUID) -> StatusLED {
        guard let controller = runningControllers[id] else {
            return .stopped
        }
        if controller.isRunning { return .running }
        if controller.isPaused { return .paused }
        return .stopped
    }

    /// Status LED states for the sidebar.
    enum StatusLED {
        case running
        case paused
        case stopped
    }

    // MARK: - Create

    /// Adds a newly created VM configuration to the library and selects it.
    ///
    /// The configuration and its on-disk bundle are assumed to already exist
    /// (created by the wizard). This method refreshes the in-memory list.
    func addCreatedVM(_ config: VMConfiguration) {
        loadConfigurations()
        selectedVMID = config.id
        showCreationWizard = false
        VortexLog.gui.info("VM added to library: \(config.identity.name)")
    }

    /// Adds an imported VM configuration to the library and selects it.
    ///
    /// The configuration and its on-disk bundle are assumed to already exist
    /// (created by the import sheet). This method refreshes the in-memory list.
    func addImportedVM(_ config: VMConfiguration) {
        loadConfigurations()
        selectedVMID = config.id
        showImportSheet = false
        VortexLog.gui.info("VM imported to library: \(config.identity.name)")
    }

    // MARK: - Delete

    /// Deletes a VM's bundle and removes it from the library.
    ///
    /// The VM must be stopped before deletion. If it is running, the error
    /// message is set and the VM is not deleted.
    func deleteVM(id: UUID) {
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
            VortexLog.gui.info("VM deleted: \(id)")
        } catch {
            errorMessage = "Failed to delete VM: \(error.localizedDescription)"
            VortexLog.gui.error("VM deletion failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Update

    /// Persists an updated configuration and refreshes the in-memory list.
    func updateVM(_ config: VMConfiguration) {
        do {
            try repo.update(config)
            // Replace in the local list.
            if let index = configurations.firstIndex(where: { $0.id == config.id }) {
                configurations[index] = config.touchingModifiedDate()
            }
            VortexLog.gui.info("VM updated: \(config.identity.name)")
        } catch {
            errorMessage = "Failed to update VM: \(error.localizedDescription)"
            VortexLog.gui.error("VM update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - OS Install Check

    /// Returns true if a macOS VM needs an OS install (disk is empty/sparse).
    func needsOSInstall(for config: VMConfiguration) -> Bool {
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
    func usesExternalResources(for config: VMConfiguration) -> Bool {
        config.usesExternalResources(bundlePath: fileManager.vmBundlePath(for: config.id))
    }
}
