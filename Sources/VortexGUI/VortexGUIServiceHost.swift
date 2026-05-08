// VortexGUIServiceHost.swift -- GUI-hosted VM owner service.
// VortexGUI

import Foundation
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
}
