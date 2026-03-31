// VortexCLI.swift — Root command group for the Vortex CLI tool.
// VortexCLI

import ArgumentParser

@main
struct VortexCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vortex",
        abstract: "Vortex Virtual Machine Monitor — command-line interface.",
        subcommands: [
            CreateVMCommand.self,
            InstallMacOSCommand.self,
            StartVMCommand.self,
            ListVMsCommand.self,
            TestAudioInterceptCommand.self,
            TestAudioRouteCommand.self,
        ]
    )
}
