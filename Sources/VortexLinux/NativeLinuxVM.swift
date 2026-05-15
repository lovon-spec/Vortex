// NativeLinuxVM.swift -- VortexHV native Linux backend.
// VortexLinux

import Foundation
import VortexAudio
import VortexCore
import VortexDevices
import VortexHV

public struct NativeLinuxFramebuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let data: Data

    public init(width: Int, height: Int, data: Data) {
        self.width = width
        self.height = height
        self.data = data
    }
}

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

    public var onFramebufferUpdated: (@Sendable (NativeLinuxFramebuffer) -> Void)? {
        didSet {
            gpu?.onFramebufferUpdated = { [weak self] framebuffer in
                self?.onFramebufferUpdated?(NativeLinuxFramebuffer(
                    width: framebuffer.width,
                    height: framebuffer.height,
                    data: framebuffer.data
                ))
            }
        }
    }

    private var uart: PL011UART?
    private var rtc: PL031RTC?
    private var flash: FlashDevice?
    private var gpu: VirtioGPUDevice?
    private var blockBackends: [any BlockStorageBackend] = []
    private var virtioTransports: [VirtioMMIOTransport] = []
    private var pciBus: PCIBus?
    private var pciHostBridge: PCIHostBridge?
    private var pciTransports: [VirtioTransport] = []
    private var networkBackends: [any NetworkPacketBackend] = []
    private var audioRouter: VortexAudio.AudioRouter?
    private var keyboardInput: VirtioInputDevice?
    private var tabletInput: VirtioInputDevice?
    private var entropyDevice: VirtioEntropyDevice?

    public init(configuration: VMConfiguration) throws {
        self.configuration = configuration
        try Self.validate(configuration)

        self.vm = try VirtualMachine(config: VMConfig(
            cpuCount: configuration.hardware.cpuCoreCount,
            ramSize: configuration.hardware.memorySize,
            kernelPath: configuration.bootConfig.kernelPath,
            initrdPath: configuration.bootConfig.initrdPath,
            bootArgs: configuration.bootConfig.kernelCommandLine ?? "",
            entryPoint: Self.entryPoint(for: configuration.bootConfig),
            bootArgumentAddress: Self.bootArgumentAddress(for: configuration.bootConfig),
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

    public func sendKey(code: UInt16, pressed: Bool) {
        keyboardInput?.sendKey(code: code, pressed: pressed)
    }

    public func sendPointer(
        x: UInt32,
        y: UInt32,
        leftButton: Bool,
        rightButton: Bool,
        middleButton: Bool
    ) {
        var buttons: VirtioInputPointerButtons = []
        if leftButton {
            buttons.insert(.left)
        }
        if rightButton {
            buttons.insert(.right)
        }
        if middleButton {
            buttons.insert(.middle)
        }
        tabletInput?.sendTabletPointer(x: x, y: y, buttons: buttons)
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
        switch configuration.bootConfig.mode {
        case .linuxKernel:
            if configuration.bootConfig.kernelPath?.isEmpty != false {
                issues.append("Native Linux backend requires bootConfig.kernelPath.")
            }
        case .uefi:
            if configuration.bootConfig.uefiFirmwarePath?.isEmpty != false {
                issues.append("Native Linux UEFI boot requires bootConfig.uefiFirmwarePath.")
            }
            if configuration.bootConfig.uefiStorePath?.isEmpty != false {
                issues.append("Native Linux UEFI boot requires bootConfig.uefiStorePath.")
            }
        case .macOS:
            issues.append("Native Linux backend cannot use macOS boot mode.")
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
        if usesPCIVirtio {
            try configurePCIVirtioDevices(memory: memory)
        } else {
            try configureMMIOVirtioDevices(memory: memory)
        }
    }

    private var usesPCIVirtio: Bool {
        configuration.bootConfig.mode == .uefi
    }

    private func configureMMIOVirtioDevices(memory: HVGuestMemoryAccessor) throws {
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

        let entropy = VirtioEntropyDevice()
        let entropyIndex = configuration.storage.disks.count
        let entropyBase = MachineMemoryMap.virtioMMIOBase
            + UInt64(entropyIndex) * MachineMemoryMap.virtioMMIODeviceStride
        let entropyIRQ = MachineIRQ.virtioMMIOBase + UInt32(entropyIndex)
        let entropyTransport = VirtioMMIOTransport(device: entropy, baseAddress: entropyBase)
        entropyTransport.attachGuestMemory(memory)
        entropyTransport.onInterruptStateChanged = { [weak vm] active in
            vm?.gic.setSPI(intid: entropyIRQ, level: active)
        }

        try vm.addDevice(entropyTransport)
        virtioTransports.append(entropyTransport)
        self.entropyDevice = entropy
    }

    private func configurePCIVirtioDevices(memory: HVGuestMemoryAccessor) throws {
        let bus = PCIBus()
        let hostBridge = PCIHostBridge(bus: bus)
        try vm.addDevice(hostBridge)

        vm.gic.msiController?.onMSIFired = { [weak vm] intid in
            vm?.gic.setSPI(intid: intid, level: true)
            vm?.gic.setSPI(intid: intid, level: false)
        }

        var usedPCISlots = Set<Int>()

        @discardableResult
        func addPCITransport(_ transport: VirtioTransport, preferredSlot: Int) throws -> Int {
            var slot = preferredSlot
            while usedPCISlots.contains(slot) {
                slot += 1
            }
            guard slot < PCIBus.maxDevices else {
                throw PCIError.busCapacityExceeded
            }
            try bus.addDevice(transport, slot: slot)
            usedPCISlots.insert(slot)
            let assignedSlot = slot
            transport.onINTxLevelChanged = { [weak vm] active in
                let line = UInt32(assignedSlot % Int(MachineIRQ.pciIntxCount))
                vm?.gic.setSPI(intid: MachineIRQ.pciIntxBase + line, level: active)
            }
            return assignedSlot
        }

        // Match QEMU virt/UTM's stable PCI topology for UEFI guests. Existing
        // UTM NVRAM boot entries commonly point the virtio-blk disk at slot 3.
        let networkBaseSlot = 1
        let gpuSlot = 2
        let blockBaseSlot = 3
        let entropySlot = 4
        let audioBaseSlot = 6
        let inputBaseSlot = 8
        var blockBootPaths: [String] = []

        for (index, disk) in configuration.storage.disks.enumerated() {
            let backend = try makeBlockBackend(for: disk)
            blockBackends.append(backend)

            let block = VirtioBlockDevice(
                backend: backend,
                serial: "VORTEX-\(configuration.id.uuidString.prefix(8))-\(index)"
            )
            let transport = VirtioTransport(
                device: block,
                msiController: vm.gic.msiController
            )
            transport.attachGuestMemory(memory)

            let slot = try addPCITransport(transport, preferredSlot: blockBaseSlot + index)
            blockBootPaths.append(FWCfgDevice.qemuPCIVirtioBlockBootPath(slot: slot))
            pciTransports.append(transport)
        }

        if !blockBootPaths.isEmpty {
            vm.fwCfg.addQEMUBootOrder(paths: blockBootPaths)
        }

        let entropy = VirtioEntropyDevice()
        let entropyTransport = VirtioTransport(
            device: entropy,
            msiController: vm.gic.msiController
        )
        entropyTransport.attachGuestMemory(memory)
        try addPCITransport(entropyTransport, preferredSlot: entropySlot)
        pciTransports.append(entropyTransport)
        self.entropyDevice = entropy

        for (index, interface) in configuration.network.interfaces.enumerated() {
            let macAddress = Self.macAddressBytes(
                configured: interface.macAddress,
                vmID: configuration.id,
                index: index
            )
            let backend = VMNetPacketBackend(
                mode: interface.mode,
                macAddress: Self.macAddressString(macAddress)
            )
            networkBackends.append(backend)

            let network = VirtioNetworkDevice(
                backend: backend,
                macAddress: macAddress
            )
            let transport = VirtioTransport(
                device: network,
                msiController: vm.gic.msiController
            )
            transport.attachGuestMemory(memory)

            try addPCITransport(transport, preferredSlot: networkBaseSlot + index)
            pciTransports.append(transport)
        }

        if configuration.audio.enabled {
            let audioRouter = VortexAudio.AudioRouter(vmID: configuration.id.uuidString)
            let sound = VirtioSound(
                audioRouter: audioRouter,
                audioConfig: configuration.audio
            )
            let transport = VirtioTransport(
                device: sound,
                msiController: vm.gic.msiController
            )
            transport.attachGuestMemory(memory)

            try addPCITransport(transport, preferredSlot: audioBaseSlot)
            pciTransports.append(transport)
            self.audioRouter = audioRouter
        }

        let keyboardInput = VirtioInputDevice(profile: .keyboard)
        let keyboardTransport = VirtioTransport(
            device: keyboardInput,
            msiController: vm.gic.msiController
        )
        keyboardTransport.attachGuestMemory(memory)
        try addPCITransport(keyboardTransport, preferredSlot: inputBaseSlot)
        pciTransports.append(keyboardTransport)
        self.keyboardInput = keyboardInput

        let tabletInput = VirtioInputDevice(profile: .tablet(
            width: UInt32(configuration.display.widthPixels),
            height: UInt32(configuration.display.heightPixels)
        ))
        let tabletTransport = VirtioTransport(
            device: tabletInput,
            msiController: vm.gic.msiController
        )
        tabletTransport.attachGuestMemory(memory)
        try addPCITransport(tabletTransport, preferredSlot: inputBaseSlot + 1)
        pciTransports.append(tabletTransport)
        self.tabletInput = tabletInput

        let gpu = VirtioGPUDevice(
            width: UInt32(configuration.display.widthPixels),
            height: UInt32(configuration.display.heightPixels)
        )
        gpu.onFramebufferUpdated = { [weak self] framebuffer in
            self?.onFramebufferUpdated?(NativeLinuxFramebuffer(
                width: framebuffer.width,
                height: framebuffer.height,
                data: framebuffer.data
            ))
        }
        let gpuTransport = VirtioTransport(
            device: gpu,
            msiController: vm.gic.msiController
        )
        gpuTransport.attachGuestMemory(memory)
        try addPCITransport(gpuTransport, preferredSlot: gpuSlot)
        pciTransports.append(gpuTransport)
        self.gpu = gpu

        try hostBridge.registerBARRegions(with: vm.addressSpace)
        self.pciBus = bus
        self.pciHostBridge = hostBridge
    }

    private func makeBlockBackend(for disk: DiskConfig) throws -> any BlockStorageBackend {
        switch disk.resolvedImageFormat {
        case .raw, .auto:
            return try RawFileBlockStorageBackend(path: disk.imagePath, readOnly: disk.readOnly)
        case .qcow2:
            if disk.imagePath.hasPrefix("ssh://") {
                return try SSHManagedQcow2BlockStorageBackend(
                    imageURLString: disk.imagePath,
                    readOnly: disk.readOnly
                )
            }
            return try ManagedQcow2BlockStorageBackend(
                imagePath: disk.imagePath,
                readOnly: disk.readOnly
            )
        }
    }

    private static func macAddressBytes(configured: String?, vmID: UUID, index: Int) -> [UInt8] {
        if let configured,
           let parsed = parseMACAddress(configured) {
            return parsed
        }

        let bytes = Array(vmID.uuidString.utf8)
        var hash = UInt64(0xcbf2_9ce4_8422_2325)
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        hash ^= UInt64(index)

        return [
            0x52, 0x54, 0x00,
            UInt8((hash >> 16) & 0xff),
            UInt8((hash >> 8) & 0xff),
            UInt8(hash & 0xff),
        ]
    }

    private static func parseMACAddress(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.count == 2, let byte = UInt8(part, radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    private static func macAddressString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private func closeBlockBackends() {
        for backend in blockBackends {
            try? backend.flush()
            backend.close()
        }
        for backend in networkBackends {
            backend.stop()
        }
        audioRouter?.stop()
        try? flash?.flush()
        flash = nil
        keyboardInput = nil
        tabletInput = nil
        blockBackends.removeAll()
        networkBackends.removeAll()
        audioRouter = nil
    }

    // MARK: - Boot

    private func loadBootPayload() throws {
        switch configuration.bootConfig.mode {
        case .linuxKernel:
            try loadDirectLinuxBootPayload()
        case .uefi:
            try loadUEFIBootPayload()
        case .macOS:
            throw VortexError.vmCreationFailed(reason: "NativeLinuxVM cannot boot macOS.")
        }
    }

    private static func entryPoint(for bootConfig: BootConfig) -> UInt64 {
        switch bootConfig.mode {
        case .uefi:
            return MachineMemoryMap.flashBase
        case .linuxKernel, .macOS:
            return MachineMemoryMap.kernelLoadAddress
        }
    }

    private static func bootArgumentAddress(for bootConfig: BootConfig) -> UInt64 {
        switch bootConfig.mode {
        case .uefi:
            return MachineMemoryMap.uefiDTBAddress
        case .linuxKernel, .macOS:
            return MachineMemoryMap.dtbAddress
        }
    }

    private func loadDirectLinuxBootPayload() throws {
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
            virtioMMIODeviceCount: usesPCIVirtio ? 0 : virtioMMIODeviceCount,
            includePCIHostBridge: usesPCIVirtio
        )
    }

    private func loadUEFIBootPayload() throws {
        guard let firmwarePath = configuration.bootConfig.uefiFirmwarePath else {
            throw VortexError.fileNotFound(path: "<uefi-firmware>")
        }
        guard let storePath = configuration.bootConfig.uefiStorePath else {
            throw VortexError.fileNotFound(path: "<uefi-vars>")
        }

        let resolvedFirmwarePath = try VortexFirmware.resolvedAArch64UEFIPath(firmwarePath)
        let firmwareData = try Self.pflashBankData(from: resolvedFirmwarePath)
        try vm.mapROM(at: MachineMemoryMap.flashBase, data: firmwareData)

        let flash: FlashDevice
        if storePath.hasPrefix("ssh://") {
            let resource = try SSHResource(urlString: storePath)
            flash = FlashDevice(
                baseAddress: MachineMemoryMap.flashBase,
                firmwareData: firmwareData,
                varsData: try Self.readSSHFile(resource),
                varsFileURL: nil,
                varsFlushHandler: { data in
                    try Self.writeSSHFile(resource, data: data)
                },
                bankSize: Int(MachineMemoryMap.flashBankSize)
            )
        } else {
            let varsURL = URL(fileURLWithPath: storePath)
            let varsData = FileManager.default.fileExists(atPath: varsURL.path)
                ? try Data(contentsOf: varsURL)
                : nil
            flash = FlashDevice(
                baseAddress: MachineMemoryMap.flashBase,
                firmwareData: firmwareData,
                varsData: varsData,
                varsFileURL: varsURL,
                bankSize: Int(MachineMemoryMap.flashBankSize)
            )
        }
        try vm.addDevice(flash)
        self.flash = flash

        _ = vm.loadDTB(
            bootArgs: "",
            at: MachineMemoryMap.uefiDTBAddress,
            virtioMMIODeviceCount: usesPCIVirtio ? 0 : virtioMMIODeviceCount,
            includePCIHostBridge: usesPCIVirtio,
            includeFirmwareDevices: true
        )
    }

    private var virtioMMIODeviceCount: Int {
        configuration.storage.disks.count + 1
    }

    private static func pflashBankData(from path: String) throws -> Data {
        var data: Data
        if path.hasPrefix("ssh://") {
            data = try readSSHFile(try SSHResource(urlString: path))
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let bankSize = Int(MachineMemoryMap.flashBankSize)
        if data.count < bankSize {
            data.append(Data(repeating: 0xFF, count: bankSize - data.count))
        } else if data.count > bankSize {
            data = data.prefix(bankSize)
        }
        return data
    }

    private static func readSSHFile(_ resource: SSHResource) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "BatchMode=yes"]
        if let port = resource.port {
            args.append(contentsOf: ["-p", String(port)])
        }
        args.append(resource.destination)
        args.append("cat \(shellQuote(resource.path))")
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw VortexError.diskOperationFailed(reason: "Failed to read \(resource.path) from \(resource.destination): \(message)")
        }
        return data
    }

    private static func writeSSHFile(_ resource: SSHResource, data: Data) throws {
        let process = Process()
        let stdin = Pipe()
        let stderr = Pipe()
        let tempPath = "\(resource.path).vortex.tmp"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "BatchMode=yes"]
        if let port = resource.port {
            args.append(contentsOf: ["-p", String(port)])
        }
        args.append(resource.destination)
        args.append("cat > \(shellQuote(tempPath)) && mv \(shellQuote(tempPath)) \(shellQuote(resource.path))")
        process.arguments = args
        process.standardInput = stdin
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(data)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw VortexError.diskOperationFailed(reason: "Failed to write \(resource.path) to \(resource.destination): \(message)")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
