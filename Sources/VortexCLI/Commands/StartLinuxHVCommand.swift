// StartLinuxHVCommand.swift -- Start a native VortexHV Linux VM.
// VortexCLI

import ArgumentParser
import Foundation
import VortexCore
import VortexDevices
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

enum LinuxHVBootModeArgument: String, ExpressibleByArgument {
    case uefi
    case linuxKernel = "linux-kernel"
}

enum LinuxHVNetworkArgument: String, ExpressibleByArgument {
    case none
    case nat
}

struct StartLinuxHVCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start-linux-hv",
        abstract: "Start a Linux ARM64 guest with the native VortexHV backend.",
        discussion: """
            Starts a Linux ARM64 guest using Vortex's Hypervisor.framework backend \
            and Vortex-owned virtio-mmio block devices. This path bypasses Apple's \
            Virtualization.framework entirely.

            UEFI boot uses a QEMU/EDK2 AArch64 firmware image plus an EFI variable \
            store. Direct kernel boot remains available with --boot linux-kernel.
            """
    )

    @Option(help: "Display name for the transient VM.")
    var name: String = "Native Linux"

    @Option(help: "Boot mode: uefi or linux-kernel.")
    var boot: LinuxHVBootModeArgument?

    @Option(help: "Path to an uncompressed ARM64 Linux kernel Image for --boot linux-kernel.")
    var kernel: String?

    @Option(help: "Optional initrd/initramfs path.")
    var initrd: String?

    @Option(help: "Path to an AArch64 EDK2 firmware code image for UEFI boot.")
    var uefiFirmware: String?

    @Option(help: "Path to an EFI variable store for UEFI boot. Defaults to efi_vars.fd next to the disk when present.")
    var efiStore: String?

    @Option(help: "Path to a RAW or qcow2 disk image.")
    var disk: String

    @Option(help: "Disk image format: auto, raw, or qcow2.")
    var diskFormat: DiskImageFormatArgument = .auto

    @Option(help: "Kernel command line for --boot linux-kernel.")
    var cmdline: String = "console=ttyAMA0 earlycon=pl011,0x09000000 root=/dev/vda rw"

    @Option(help: "Number of virtual CPUs.")
    var cpu: Int = 4

    @Option(help: "Memory in MiB.")
    var memory: UInt64 = 4096

    @Option(help: "Network mode: nat or none.")
    var network: LinuxHVNetworkArgument = .nat

    @Option(help: "Optional path to write the latest native framebuffer as a binary PPM image.")
    var framebufferDump: String?

    @Option(help: "Optional interval in seconds for printing vCPU diagnostics.")
    var diagnosticsInterval: Double?

    func run() throws {
        let diskSize: UInt64
        if disk.hasPrefix("ssh://") {
            diskSize = 1
        } else {
            let diskURL = URL(fileURLWithPath: disk)
            diskSize = try diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(UInt64.init) ?? 0
        }
        let resolvedBoot = boot ?? (kernel == nil ? .uefi : .linuxKernel)
        let bootConfig = try makeBootConfig(mode: resolvedBoot)

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
            network: network == .nat ? .singleNAT : .none,
            display: .standard,
            audio: .disabled,
            clipboard: .disabled,
            rosetta: .disabled,
            bootConfig: bootConfig
        )

        let vm = try NativeLinuxVM(configuration: config)
        vm.onSerialOutput = { byte in
            FileHandle.standardOutput.write(Data([byte]))
        }
        if let framebufferDump {
            vm.onFramebufferUpdated = { framebuffer in
                do {
                    try Self.writeFramebufferDump(framebuffer, to: framebufferDump)
                } catch {
                    let message = "Failed to write framebuffer dump: \(error)\n"
                    FileHandle.standardError.write(Data(message.utf8))
                }
            }
        }

        print("Starting native VortexHV Linux VM...")
        switch resolvedBoot {
        case .linuxKernel:
            print("  Kernel: \(kernel ?? "")")
        case .uefi:
            print("  Firmware: \(config.bootConfig.uefiFirmwarePath ?? "")")
            print("  EFI vars: \(config.bootConfig.uefiStorePath ?? "")")
        }
        print("  Disk:   \(disk) (\(config.storage.bootDisk?.resolvedImageFormat.rawValue ?? "unknown"))")
        print("  CPU:    \(cpu)")
        print("  Memory: \(memory) MiB")
        print("  Network: \(network.rawValue)")
        print("")

        var shouldStop = false
        var lifecycleError: String?
        vm.vm.lifecycle.onStateChange = { state, _ in
            switch state {
            case .stopped:
                shouldStop = true
                CFRunLoopStop(CFRunLoopGetMain())
            case .error:
                lifecycleError = vm.vm.lifecycle.errorMessage
                shouldStop = true
                CFRunLoopStop(CFRunLoopGetMain())
            case .starting, .running, .paused, .stopping:
                break
            }
        }

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            shouldStop = true
            try? vm.stop()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        source.resume()

        var diagnosticsTimer: DispatchSourceTimer?
        if let diagnosticsInterval, diagnosticsInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(
                deadline: .now() + diagnosticsInterval,
                repeating: diagnosticsInterval
            )
            timer.setEventHandler {
                for snapshot in vm.vm.vcpuDiagnostics(forceExit: true) {
                    let reason = snapshot.lastExitReason.map(String.init) ?? "none"
                    print("[diag] vCPU \(snapshot.index) running=\(snapshot.isRunning) pc=0x\(String(snapshot.lastPC, radix: 16)) exit=\(reason) exits=\(snapshot.exitCount)")
                }
            }
            timer.resume()
            diagnosticsTimer = timer
        }

        try vm.start()
        while !shouldStop {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
        diagnosticsTimer?.cancel()

        if let lifecycleError {
            throw RuntimeError(lifecycleError)
        }
    }

    private static func writeFramebufferDump(
        _ framebuffer: NativeLinuxFramebuffer,
        to path: String
    ) throws {
        let pixelCount = framebuffer.width * framebuffer.height
        let expectedBytes = pixelCount * 4
        guard framebuffer.width > 0,
              framebuffer.height > 0,
              framebuffer.data.count >= expectedBytes else {
            return
        }

        var imageData = Data("P6\n\(framebuffer.width) \(framebuffer.height)\n255\n".utf8)
        imageData.reserveCapacity(imageData.count + pixelCount * 3)

        let pixels = framebuffer.data.prefix(expectedBytes)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            imageData.append(pixels[offset + 2])
            imageData.append(pixels[offset + 1])
            imageData.append(pixels[offset])
        }

        try imageData.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func makeBootConfig(mode: LinuxHVBootModeArgument) throws -> BootConfig {
        switch mode {
        case .linuxKernel:
            guard let kernel else {
                throw ValidationError("--kernel is required for --boot linux-kernel.")
            }
            return .linuxKernel(
                kernelPath: kernel,
                commandLine: cmdline,
                initrdPath: initrd
            )

        case .uefi:
            let firmwarePath = try uefiFirmware ?? Self.findAArch64UEFIFirmware(nearDisk: disk)
            let storePath = try efiStore ?? Self.inferEFIStorePath(nextToDisk: disk)
            return .uefi(storePath: storePath, firmwarePath: firmwarePath)
        }
    }

    private static func inferEFIStorePath(nextToDisk disk: String) throws -> String {
        if disk.hasPrefix("ssh://") {
            let resource = try SSHResource(urlString: disk)
            let parent = (resource.path as NSString).deletingLastPathComponent
            let efiPath = (parent as NSString).appendingPathComponent("efi_vars.fd")
            var components = URLComponents()
            components.scheme = "ssh"
            components.user = resource.user
            components.host = resource.host
            components.port = resource.port
            components.path = efiPath
            if let url = components.url?.absoluteString {
                return url
            }
            throw ValidationError("Could not infer remote EFI variable store URL.")
        } else {
            let candidate = URL(fileURLWithPath: disk)
                .deletingLastPathComponent()
                .appendingPathComponent("efi_vars.fd")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        throw ValidationError("--efi-store is required for UEFI boot when efi_vars.fd is not next to the disk.")
    }

    private static func findAArch64UEFIFirmware(nearDisk disk: String) throws -> String {
        let fileManager = FileManager.default
        let candidates = localAArch64UEFIFirmwareCandidates()

        if let remoteEnv = candidates.first(where: { $0.hasPrefix("ssh://") }) {
            return remoteEnv
        }
        if let match = candidates.first(where: { fileManager.fileExists(atPath: $0) }) {
            return match
        }

        if disk.hasPrefix("ssh://"),
           let remoteMatch = try findRemoteAArch64UEFIFirmware(nearDisk: disk) {
            return remoteMatch
        }

        throw ValidationError("AArch64 UEFI firmware was not found. Pass --uefi-firmware or set VORTEX_AARCH64_UEFI.")
    }

    private static func localAArch64UEFIFirmwareCandidates() -> [String] {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let envPath = ProcessInfo.processInfo.environment["VORTEX_AARCH64_UEFI"],
           !envPath.isEmpty {
            candidates.append(envPath)
        }

        candidates.append(contentsOf: [
            "/Applications/UTM.app/Contents/Resources/qemu/edk2-aarch64-code.fd",
            "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
            "/usr/local/share/qemu/edk2-aarch64-code.fd",
        ])

        for cellar in ["/opt/homebrew/Cellar/qemu", "/usr/local/Cellar/qemu"] {
            if let versions = try? fileManager.contentsOfDirectory(atPath: cellar) {
                candidates.append(contentsOf: versions.map {
                    ((cellar as NSString).appendingPathComponent($0) as NSString)
                        .appendingPathComponent("share/qemu/edk2-aarch64-code.fd")
                })
            }
        }
        return candidates
    }

    private static func findRemoteAArch64UEFIFirmware(nearDisk disk: String) throws -> String? {
        let resource = try SSHResource(urlString: disk)
        let command = """
        for p in /Applications/UTM.app/Contents/Resources/qemu/edk2-aarch64-code.fd /opt/homebrew/share/qemu/edk2-aarch64-code.fd /usr/local/share/qemu/edk2-aarch64-code.fd; do \
        [ -f "$p" ] && printf '%s' "$p" && exit 0; done; \
        found=$(find /opt/homebrew/Cellar/qemu /usr/local/Cellar/qemu -path '*/share/qemu/edk2-aarch64-code.fd' -type f -print -quit 2>/dev/null); \
        [ -n "$found" ] && printf '%s' "$found" && exit 0; exit 1
        """

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "BatchMode=yes"]
        if let port = resource.port {
            args.append(contentsOf: ["-p", String(port)])
        }
        args.append(resource.destination)
        args.append(command)
        process.arguments = args
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8),
              !path.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "ssh"
        components.user = resource.user
        components.host = resource.host
        components.port = resource.port
        components.path = path
        return components.url?.absoluteString
    }
}

private struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
