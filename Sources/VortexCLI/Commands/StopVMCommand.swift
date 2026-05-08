// StopVMCommand.swift -- Request a running Vortex service to stop one VM.
// VortexCLI

import ArgumentParser
import Foundation
import VortexService

struct StopVMCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop-vm",
        abstract: "Request the running Vortex service to stop a VM."
    )

    @Option(
        name: .long,
        help: "UUID of the VM to stop."
    )
    var vm: String

    func run() throws {
        guard let vmID = UUID(uuidString: vm) else {
            print("error: '\(vm)' is not a valid UUID.")
            throw ExitCode.validationFailure
        }

        let command = VortexServiceCommand(kind: .stopVM, vmID: vmID)
        guard VortexServiceControlClient.forwardToRunningService(command) else {
            print("error: no running Vortex service accepted the stop request.")
            throw ExitCode.failure
        }

        print("Requested running Vortex service to stop VM \(vmID.uuidString).")
    }
}
