// StartLinuxHVCommand.swift -- Start a native VortexHV Linux VM.
// VortexCLI

import ArgumentParser
import Foundation
import VortexCore
import VortexLinux

enum DiskImageFormatArgument: String, ExpressibleByArgument {
    case auto
    case raw
    case qcow2

    var imageFormat: DiskImageFormat {
        switch self {
        case .auto:
            return .auto
        case .raw:
            return .raw
        case .qcow2:
            return .qcow2
        }
    }
}

struct StartLinuxHVCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start-linux-hv",
        abstract: "Start a Linux ARM64 guest with the native VortexHV backend.",
        discussion: """
            Starts a Linux ARM64 guest using Vortex's Hypervisor.framework backend \
            and Vortex-owned virtio-mmio block devices. This path bypasses Apple's \
            Virtualization.framework entirely.

            The current boot path is direct kernel boot. Use an uncompressed ARM64 \
            Linux Image and pass a root= argument that matches the imported disk \
            layout, for example root=/dev/vda2.
            """
    )

    @Option(help: "Display name for the transient VM.")
    var name: String = "Native Linux"

    @Option(help: "Path to an uncompressed ARM64 Linux kernel Image.")
    var kernel: String

    @Option(help: "Optional initrd/initramfs path.")
    var initrd: String?

    @Option(help: "Path to a RAW or qcow2 disk image.")
    var disk: String

    @Option(help: "Disk image format: auto, raw, or qcow2.")
    var diskFormat: DiskImageFormatArgument = .auto

    @Option(help: "Kernel command line.")
    var cmdline: String = "console=ttyAMA0 earlycon=pl011,0x09000000 root=/dev/vda rw"

    @Option(help: "Number of virtual CPUs.")
    var cpu: Int = 4

    @Option(help: "Memory in MiB.")
    var memory: UInt64 = 4096

    func run() throws {
        let diskURL = URL(fileURLWithPath: disk)
        let diskSize = try diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(UInt64.init) ?? 0

        let config = VMConfiguration(
            identity: VMIdentity(name: name, iconName: "pc"),
            guestOS: .linuxARM64,
            backend: .vortexHV,
            hardware: HardwareProfile(cpuCoreCount: cpu, memorySize: memory * 1024 * 1024),
            storage: StorageConfiguration(disks: [
                DiskConfig(
                    label: "Boot Disk",
                    imagePath: disk,
                    imageFormat: diskFormat.imageFormat,
                    sizeBytes: diskSize,
                    deviceType: .virtioBlock,
                    cachingMode: .automatic,
                    syncMode: .full,
                    readOnly: false
                )
            ]),
            network: .none,
            display: .standard,
            audio: .disabled,
            clipboard: .disabled,
            rosetta: .disabled,
            bootConfig: .linuxKernel(
                kernelPath: kernel,
                commandLine: cmdline,
                initrdPath: initrd
            )
        )

        let vm = try NativeLinuxVM(configuration: config)
        vm.onSerialOutput = { byte in
            FileHandle.standardOutput.write(Data([byte]))
        }

        print("Starting native VortexHV Linux VM...")
        print("  Kernel: \(kernel)")
        print("  Disk:   \(disk) (\(config.storage.bootDisk?.resolvedImageFormat.rawValue ?? "unknown"))")
        print("  CPU:    \(cpu)")
        print("  Memory: \(memory) MiB")
        print("")

        var shouldStop = false
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            shouldStop = true
            try? vm.stop()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        source.resume()

        try vm.start()
        while !shouldStop {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }
}
