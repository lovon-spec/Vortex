// NativeLinuxVM.swift -- VortexHV native Linux backend.
// VortexLinux

import Foundation
import VortexCore
import VortexDevices
import VortexHV

/// Native Linux VM backed by Hypervisor.framework and Vortex-owned devices.
public final class NativeLinuxVM: @unchecked Sendable {
    public let configuration: VMConfiguration
    public let vm: VirtualMachine

    /// Serial console output from the guest PL011 UART.
    public var onSerialOutput: ((UInt8) -> Void)? {
        didSet {
            uart?.onOutput = onSerialOutput
        }
    }

    private var uart: PL011UART?
    private var rtc: PL031RTC?
    private var blockBackends: [any BlockStorageBackend] = []
    private var virtioTransports: [VirtioMMIOTransport] = []

    public init(configuration: VMConfiguration) throws {
        self.configuration = configuration
        try Self.validate(configuration)

        self.vm = try VirtualMachine(config: VMConfig(
            cpuCount: configuration.hardware.cpuCoreCount,
            ramSize: configuration.hardware.memorySize,
            kernelPath: configuration.bootConfig.kernelPath,
            initrdPath: configuration.bootConfig.initrdPath,
            bootArgs: configuration.bootConfig.kernelCommandLine ?? "",
            guestOS: .linux
        ))

        do {
            try configurePlatform()
            try loadBootPayload()
        } catch {
            closeBlockBackends()
            throw error
        }
    }

    public func start() throws {
        try vm.start()
    }

    public func stop() throws {
        defer { closeBlockBackends() }
        try vm.stop()
    }

    // MARK: - Validation

    private static func validate(_ configuration: VMConfiguration) throws {
        var issues = configuration.validate()

        if configuration.backend != .vortexHV {
            issues.append("NativeLinuxVM requires backend=vortexHV.")
        }
        if configuration.guestOS != .linuxARM64 {
            issues.append("NativeLinuxVM requires Linux ARM64 guest OS.")
        }
        if configuration.bootConfig.mode != .linuxKernel {
            issues.append("Native Linux backend currently requires direct Linux kernel boot.")
        }
        if configuration.bootConfig.kernelPath?.isEmpty != false {
            issues.append("Native Linux backend requires bootConfig.kernelPath.")
        }

        if !issues.isEmpty {
            throw VortexError.invalidConfiguration(issues: issues)
        }
    }

    // MARK: - Platform

    private func configurePlatform() throws {
        let uart = PL011UART()
        uart.onOutput = onSerialOutput
        uart.onInterruptStateChanged = { [weak vm] active in
            vm?.gic.setSPI(intid: MachineIRQ.uart0, level: active)
        }
        try vm.addDevice(uart)
        self.uart = uart

        let rtc = PL031RTC()
        rtc.onInterruptStateChanged = { [weak vm] active in
            vm?.gic.setSPI(intid: MachineIRQ.rtc, level: active)
        }
        try vm.addDevice(rtc)
        self.rtc = rtc

        let memory = HVGuestMemoryAccessor(memoryManager: vm.memoryManager)
        for (index, disk) in configuration.storage.disks.enumerated() {
            let backend = try makeBlockBackend(for: disk)
            blockBackends.append(backend)

            let block = VirtioBlockDevice(
                backend: backend,
                serial: "VORTEX-\(configuration.id.uuidString.prefix(8))-\(index)"
            )
            let base = MachineMemoryMap.virtioMMIOBase
                + UInt64(index) * MachineMemoryMap.virtioMMIODeviceStride
            let irq = MachineIRQ.virtioMMIOBase + UInt32(index)
            let transport = VirtioMMIOTransport(device: block, baseAddress: base)
            transport.attachGuestMemory(memory)
            transport.onInterruptStateChanged = { [weak vm] active in
                vm?.gic.setSPI(intid: irq, level: active)
            }

            try vm.addDevice(transport)
            virtioTransports.append(transport)
        }
    }

    private func makeBlockBackend(for disk: DiskConfig) throws -> any BlockStorageBackend {
        switch disk.resolvedImageFormat {
        case .raw, .auto:
            return try RawFileBlockStorageBackend(path: disk.imagePath, readOnly: disk.readOnly)
        case .qcow2:
            return try ManagedQcow2BlockStorageBackend(
                imagePath: disk.imagePath,
                readOnly: disk.readOnly
            )
        }
    }

    private func closeBlockBackends() {
        for backend in blockBackends {
            try? backend.flush()
            backend.close()
        }
        blockBackends.removeAll()
    }

    // MARK: - Boot

    private func loadBootPayload() throws {
        guard let kernelPath = configuration.bootConfig.kernelPath else {
            throw VortexError.fileNotFound(path: "<kernel>")
        }

        try vm.loadFile(
            at: URL(fileURLWithPath: kernelPath),
            gpa: MachineMemoryMap.kernelLoadAddress
        )

        var initrdStart: UInt64?
        var initrdEnd: UInt64?
        if let initrdPath = configuration.bootConfig.initrdPath {
            let initrdURL = URL(fileURLWithPath: initrdPath)
            let initrdData = try Data(contentsOf: initrdURL)
            vm.loadData(initrdData, at: MachineMemoryMap.initrdLoadAddress)
            initrdStart = MachineMemoryMap.initrdLoadAddress
            initrdEnd = MachineMemoryMap.initrdLoadAddress + UInt64(initrdData.count)
        }

        _ = vm.loadDTB(
            bootArgs: configuration.bootConfig.kernelCommandLine,
            initrdStart: initrdStart,
            initrdEnd: initrdEnd,
            virtioMMIODeviceCount: configuration.storage.disks.count
        )
    }
}
