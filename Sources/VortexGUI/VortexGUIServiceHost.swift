// VortexGUIServiceHost.swift -- GUI-hosted VM owner service.
// VortexGUI

import Foundation
import AppKit
import Observation
import VortexService

@MainActor
@Observable
final class VortexGUIServiceHost {
    let viewModel: VMLibraryViewModel
    let displayCoordinator = VMDisplayCoordinator()
    private(set) var isControlServerRunning: Bool = false

    private let controlServer = VortexServiceControlServer()
    private var commandHandler: ((VortexServiceCommand) -> Void)?
    private var pendingCommands: [VortexServiceCommand]
    private weak var libraryWindow: NSWindow?

    init(initialCommand: VortexServiceCommand) {
        self.viewModel = VMLibraryViewModel()
        self.pendingCommands = [initialCommand]

        isControlServerRunning = controlServer.start { [weak self] command in
            self?.dispatch(command)
        }
    }

    func installCommandHandler(_ handler: @escaping (VortexServiceCommand) -> Void) {
        commandHandler = handler

        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands {
            handler(command)
        }
    }

    private func dispatch(_ command: VortexServiceCommand) {
        guard let commandHandler else {
            pendingCommands.append(command)
            return
        }
        commandHandler(command)
    }

    @MainActor
    func registerLibraryWindow(_ window: NSWindow) -> Bool {
        if let existing = liveLibraryWindow(), existing !== window {
            focusLibraryWindow(existing)
            closeDuplicateWindow(window)
            return false
        }

        window.identifier = .vortexLibraryWindow
        window.title = "Vortex"
        window.isReleasedWhenClosed = false
        libraryWindow = window
        return true
    }

    @MainActor
    func focusLibraryWindow() {
        guard let window = liveLibraryWindow() else { return }
        focusLibraryWindow(window)
    }

    @MainActor
    private func liveLibraryWindow() -> NSWindow? {
        if let libraryWindow {
            return libraryWindow
        }

        if let window = NSApp.windows.first(where: { $0.identifier == .vortexLibraryWindow }) {
            libraryWindow = window
            return window
        }

        return nil
    }

    @MainActor
    private func focusLibraryWindow(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func closeDuplicateWindow(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }
}

extension NSUserInterfaceItemIdentifier {
    static let vortexLibraryWindow = NSUserInterfaceItemIdentifier("com.vortex.library")
}
