// DTBBuilder.swift -- Flattened Device Tree (FDT) builder for ARM64 VMs.
// VortexHV
//
// Builds a minimal device tree blob (DTB) compatible with the Linux kernel
// and other ARM64 boot loaders. Follows the Devicetree Specification v0.4.
//
// FDT binary format:
// [fdt_header] [memory reservation block] [structure block] [strings block]

import Foundation

// MARK: - FDT Constants

private let FDT_MAGIC: UInt32 = 0xD00D_FEED
private let FDT_VERSION: UInt32 = 17
private let FDT_LAST_COMP_VERSION: UInt32 = 16

private let FDT_BEGIN_NODE: UInt32 = 0x0000_0001
private let FDT_END_NODE: UInt32 = 0x0000_0002
private let FDT_PROP: UInt32 = 0x0000_0003
private let FDT_NOP: UInt32 = 0x0000_0004
private let FDT_END: UInt32 = 0x0000_0009

// MARK: - DTB Builder

/// Builds a Flattened Device Tree (FDT) binary for ARM64 VM boot.
///
/// Usage:
/// ```swift
/// let dtb = DTBBuilder(
///     cpuCount: 4,
///     ramBase: 0x4000_0000,
///     ramSize: 1 * 1024 * 1024 * 1024,
///     bootArgs: "console=ttyAMA0 earlycon"
/// )
/// let data = dtb.build()
/// ```
public final class DTBBuilder {
    private let cpuCount: Int
    private let ramBase: UInt64
    private let ramSize: UInt64
    private let bootArgs: String
    private let gicDistBase: UInt64
    private let gicRedistBase: UInt64
    private let gicRedistSize: UInt64
    private let uartBase: UInt64
    private let uartIRQ: UInt32
    private let rtcBase: UInt64
    private let rtcIRQ: UInt32
    private let virtioMMIODeviceCount: Int
    private let virtioMMIOBase: UInt64
    private let virtioMMIOSize: UInt64
    private let virtioMMIOStride: UInt64
    private let virtioMMIOIRQBase: UInt32
    private let includePCIHostBridge: Bool
    private let includeFirmwareDevices: Bool
    private let initrdStart: UInt64?
    private let initrdEnd: UInt64?

    // FDT construction state
    private var structureBlock = Data()
    private var stringsBlock = Data()
    private var stringOffsets: [String: UInt32] = [:]

    public init(
        cpuCount: Int,
        ramBase: UInt64 = MachineMemoryMap.ramBase,
        ramSize: UInt64,
        bootArgs: String = "",
        gicDistBase: UInt64 = MachineMemoryMap.gicDistributorBase,
        gicRedistBase: UInt64 = MachineMemoryMap.gicRedistributorBase,
        gicRedistSize: UInt64? = nil,
        uartBase: UInt64 = MachineMemoryMap.uart0Base,
        uartIRQ: UInt32 = MachineIRQ.uart0,
        rtcBase: UInt64 = MachineMemoryMap.rtcBase,
        rtcIRQ: UInt32 = MachineIRQ.rtc,
        virtioMMIODeviceCount: Int = 0,
        virtioMMIOBase: UInt64 = MachineMemoryMap.virtioMMIOBase,
        virtioMMIOSize: UInt64 = MachineMemoryMap.virtioMMIODeviceSize,
        virtioMMIOStride: UInt64 = MachineMemoryMap.virtioMMIODeviceStride,
        virtioMMIOIRQBase: UInt32 = MachineIRQ.virtioMMIOBase,
        includePCIHostBridge: Bool = false,
        includeFirmwareDevices: Bool = false,
        initrdStart: UInt64? = nil,
        initrdEnd: UInt64? = nil
    ) {
        self.cpuCount = cpuCount
        self.ramBase = ramBase
        self.ramSize = ramSize
        self.bootArgs = bootArgs
        self.gicDistBase = gicDistBase
        self.gicRedistBase = gicRedistBase
        self.gicRedistSize = gicRedistSize ?? (UInt64(cpuCount) * MachineMemoryMap.gicRedistributorPerCPUSize)
        self.uartBase = uartBase
        self.uartIRQ = uartIRQ
        self.rtcBase = rtcBase
        self.rtcIRQ = rtcIRQ
        self.virtioMMIODeviceCount = virtioMMIODeviceCount
        self.virtioMMIOBase = virtioMMIOBase
        self.virtioMMIOSize = virtioMMIOSize
        self.virtioMMIOStride = virtioMMIOStride
        self.virtioMMIOIRQBase = virtioMMIOIRQBase
        self.includePCIHostBridge = includePCIHostBridge
        self.includeFirmwareDevices = includeFirmwareDevices
        self.initrdStart = initrdStart
        self.initrdEnd = initrdEnd
    }

    /// Build the complete FDT binary.
    public func build() -> Data {
        structureBlock = Data()
        stringsBlock = Data()
        stringOffsets = [:]

        buildTree()

        return assembleFDT()
    }

    // MARK: - Tree Construction

    private func buildTree() {
        beginNode("")  // Root node

        addProperty("compatible", stringList: ["linux,dummy-virt"])
        addProperty("#address-cells", u32: 2)
        addProperty("#size-cells", u32: 2)
        addProperty("interrupt-parent", u32: 1) // phandle of GIC

        // -- chosen node --
        buildChosenNode()

        // -- memory node --
        buildMemoryNode()

        // -- CPU nodes --
        buildCPUNodes()

        // -- timer node --
        buildTimerNode()

        // -- GIC node --
        buildGICNode()

        // -- UART node --
        buildUARTNode()

        // -- RTC node --
        buildRTCNode()

        // -- QEMU firmware platform devices --
        buildFirmwareDeviceNodes()

        // -- virtio-mmio devices --
        buildVirtioMMIONodes()

        // -- PCI host bridge --
        buildPCIHostBridgeNode()

        // -- PSCI node --
        buildPSCINode()

        endNode() // Root
    }

    private func buildChosenNode() {
        beginNode("chosen")
        addProperty("stdout-path", string: "/uart@\(String(uartBase, radix: 16))")
        if !bootArgs.isEmpty {
            addProperty("bootargs", string: bootArgs)
        }
        if let start = initrdStart, let end = initrdEnd {
            addProperty("linux,initrd-start", u64: start)
            addProperty("linux,initrd-end", u64: end)
        }
        endNode()
    }

    private func buildMemoryNode() {
        beginNode("memory@\(String(ramBase, radix: 16))")
        addProperty("device_type", string: "memory")
        addProperty("reg", u64Pair: (ramBase, ramSize))
        endNode()
    }

    private func buildCPUNodes() {
        beginNode("cpus")
        addProperty("#address-cells", u32: 1)
        addProperty("#size-cells", u32: 0)

        for i in 0..<cpuCount {
            beginNode("cpu@\(i)")
            addProperty("device_type", string: "cpu")
            addProperty("compatible", stringList: ["arm,arm-v8"])
            addProperty("reg", u32: UInt32(i))
            addProperty("enable-method", string: "psci")
            endNode()
        }

        endNode() // cpus
    }

    private func buildTimerNode() {
        beginNode("timer")
        addProperty("compatible", stringList: ["arm,armv8-timer"])
        addProperty("always-on", empty: true)
        // GIC interrupt specifier: type(0=SPI,1=PPI), number, flags
        // Secure Physical Timer PPI (INTID 29 -> PPI 13)
        // Non-secure Physical Timer PPI (INTID 30 -> PPI 14)
        // Virtual Timer PPI (INTID 27 -> PPI 11)
        // Hypervisor Timer PPI (INTID 26 -> PPI 10)
        let interrupts: [UInt32] = [
            1, 13, 0xF08,  // Secure Physical Timer
            1, 14, 0xF08,  // Non-secure Physical Timer
            1, 11, 0xF08,  // Virtual Timer
            1, 10, 0xF08,  // Hypervisor Timer
        ]
        addProperty("interrupts", u32Array: interrupts)
        endNode()
    }

    private func buildGICNode() {
        beginNode("intc@\(String(gicDistBase, radix: 16))")
        addProperty("compatible", stringList: ["arm,gic-v3"])
        addProperty("#interrupt-cells", u32: 3)
        addProperty("#address-cells", u32: 2)
        addProperty("#size-cells", u32: 2)
        addProperty("interrupt-controller", empty: true)
        addProperty("phandle", u32: 1) // Referenced by interrupt-parent

        // reg: distributor base/size, redistributor base/size
        let regData = encodeU64Array([
            gicDistBase, MachineMemoryMap.gicDistributorSize,
            gicRedistBase, gicRedistSize,
        ])
        addProperty("reg", data: regData)

        addProperty("ranges", empty: true)
        endNode()
    }

    private func buildUARTNode() {
        beginNode("uart@\(String(uartBase, radix: 16))")
        addProperty("compatible", stringList: ["arm,pl011", "arm,primecell"])
        addProperty("reg", u64Pair: (uartBase, MachineMemoryMap.uart0Size))
        // GIC interrupt: SPI, intid - 32, level-sensitive high
        let spiNumber = uartIRQ - 32
        let interrupts: [UInt32] = [0, spiNumber, 4] // SPI, number, IRQ_TYPE_LEVEL_HIGH
        addProperty("interrupts", u32Array: interrupts)
        addProperty("clock-names", stringList: ["uartclk", "apb_pclk"])
        // Fixed clocks: 24 MHz UART clock
        let clocks: [UInt32] = [0x1800_0000, 0x1800_0000] // 24 MHz in Hz
        addProperty("clocks", u32Array: clocks)
        endNode()
    }

    private func buildRTCNode() {
        beginNode("rtc@\(String(rtcBase, radix: 16))")
        addProperty("compatible", stringList: ["arm,pl031", "arm,primecell"])
        addProperty("reg", u64Pair: (rtcBase, MachineMemoryMap.rtcSize))
        let spiNumber = rtcIRQ - 32
        addProperty("interrupts", u32Array: [0, spiNumber, 4])
        addProperty("clock-names", stringList: ["apb_pclk"])
        addProperty("clocks", u32Array: [0x1800_0000])
        endNode()
    }

    private func buildFirmwareDeviceNodes() {
        guard includeFirmwareDevices else { return }

        beginNode("flash@0")
        addProperty("compatible", stringList: ["cfi-flash"])
        addProperty("bank-width", u32: 4)
        addProperty("reg", data: encodeU64Array([
            MachineMemoryMap.flashBase,
            MachineMemoryMap.flashBankSize,
            MachineMemoryMap.flashBase + MachineMemoryMap.flashBankSize,
            MachineMemoryMap.flashBankSize,
        ]))
        endNode()

        beginNode("fw-cfg@\(String(MachineMemoryMap.fwCfgBase, radix: 16))")
        addProperty("compatible", stringList: ["qemu,fw-cfg-mmio"])
        addProperty("reg", u64Pair: (MachineMemoryMap.fwCfgBase, 0x18))
        endNode()
    }

    private func buildVirtioMMIONodes() {
        guard virtioMMIODeviceCount > 0 else { return }

        for index in 0..<virtioMMIODeviceCount {
            let base = virtioMMIOBase + UInt64(index) * virtioMMIOStride
            let intid = virtioMMIOIRQBase + UInt32(index)
            beginNode("virtio_mmio@\(String(base, radix: 16))")
            addProperty("compatible", stringList: ["virtio,mmio"])
            addProperty("reg", u64Pair: (base, virtioMMIOSize))
            addProperty("interrupts", u32Array: [0, intid - 32, 4])
            endNode()
        }
    }

    private func buildPCIHostBridgeNode() {
        guard includePCIHostBridge else { return }

        beginNode("pcie@\(String(MachineMemoryMap.pciEcamBase, radix: 16))")
        addProperty("compatible", stringList: ["pci-host-ecam-generic"])
        addProperty("device_type", string: "pci")
        addProperty("#address-cells", u32: 3)
        addProperty("#size-cells", u32: 2)
        addProperty("#interrupt-cells", u32: 1)
        addProperty("reg", u64Pair: (MachineMemoryMap.pciEcamBase, MachineMemoryMap.pciEcamSize))
        addProperty("bus-range", u32Array: [0, 0])
        addProperty("dma-coherent", empty: true)

        var ranges: [UInt32] = []
        appendPCIAddress(&ranges, space: 0x0200_0000, address: MachineMemoryMap.pciMmio32Base)
        appendU64Cells(&ranges, MachineMemoryMap.pciMmio32Base)
        appendU64Cells(&ranges, MachineMemoryMap.pciMmio32Size)
        appendPCIAddress(&ranges, space: 0x0300_0000, address: MachineMemoryMap.pciMmio64Base)
        appendU64Cells(&ranges, MachineMemoryMap.pciMmio64Base)
        appendU64Cells(&ranges, MachineMemoryMap.pciMmio64Size)
        addProperty("ranges", u32Array: ranges)

        addProperty("interrupt-map-mask", u32Array: [0x0000_F800, 0, 0, 7])
        addProperty("interrupt-map", u32Array: buildPCIInterruptMap())
        endNode()
    }

    private func buildPCIInterruptMap() -> [UInt32] {
        var values: [UInt32] = []
        for slot in 0..<PCIBus.maxDevices {
            for pin in 1...4 {
                values.append(UInt32(slot) << 11)
                values.append(0)
                values.append(0)
                values.append(UInt32(pin))
                values.append(1) // GIC phandle
                let line = UInt32((slot + pin - 1) % Int(MachineIRQ.pciIntxCount))
                values.append(0)
                values.append(MachineIRQ.pciIntxBase + line - 32)
                values.append(4)
            }
        }
        return values
    }

    private func appendPCIAddress(_ values: inout [UInt32], space: UInt32, address: UInt64) {
        values.append(space)
        values.append(UInt32(truncatingIfNeeded: address >> 32))
        values.append(UInt32(truncatingIfNeeded: address))
    }

    private func appendU64Cells(_ values: inout [UInt32], _ value: UInt64) {
        values.append(UInt32(truncatingIfNeeded: value >> 32))
        values.append(UInt32(truncatingIfNeeded: value))
    }

    private func buildPSCINode() {
        beginNode("psci")
        addProperty("compatible", stringList: ["arm,psci-1.0", "arm,psci-0.2"])
        addProperty("method", string: "hvc")
        endNode()
    }

    // MARK: - FDT Primitives

    private func beginNode(_ name: String) {
        appendU32(&structureBlock, FDT_BEGIN_NODE)
        appendString(&structureBlock, name)
        alignTo4(&structureBlock)
    }

    private func endNode() {
        appendU32(&structureBlock, FDT_END_NODE)
    }

    private func addProperty(_ name: String, data: Data) {
        let nameOffset = internString(name)
        appendU32(&structureBlock, FDT_PROP)
        appendU32(&structureBlock, UInt32(data.count))
        appendU32(&structureBlock, nameOffset)
        structureBlock.append(data)
        alignTo4(&structureBlock)
    }

    private func addProperty(_ name: String, string: String) {
        var data = Data(string.utf8)
        data.append(0) // NUL terminator
        addProperty(name, data: data)
    }

    private func addProperty(_ name: String, stringList: [String]) {
        var data = Data()
        for s in stringList {
            data.append(contentsOf: s.utf8)
            data.append(0)
        }
        addProperty(name, data: data)
    }

    private func addProperty(_ name: String, u32: UInt32) {
        var data = Data(count: 4)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: u32.bigEndian, as: UInt32.self)
        }
        addProperty(name, data: data)
    }

    private func addProperty(_ name: String, u64: UInt64) {
        var data = Data(count: 8)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: u64.bigEndian, as: UInt64.self)
        }
        addProperty(name, data: data)
    }

    private func addProperty(_ name: String, u64Pair: (UInt64, UInt64)) {
        var data = Data(count: 16)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: u64Pair.0.bigEndian, toByteOffset: 0, as: UInt64.self)
            ptr.storeBytes(of: u64Pair.1.bigEndian, toByteOffset: 8, as: UInt64.self)
        }
        addProperty(name, data: data)
    }

    private func addProperty(_ name: String, u32Array: [UInt32]) {
        var data = Data(count: u32Array.count * 4)
        data.withUnsafeMutableBytes { ptr in
            for (i, val) in u32Array.enumerated() {
                ptr.storeBytes(of: val.bigEndian, toByteOffset: i * 4, as: UInt32.self)
            }
        }
        addProperty(name, data: data)
    }

    private func addProperty(_ name: String, empty: Bool) {
        addProperty(name, data: Data())
    }

    // MARK: - String Interning

    private func internString(_ name: String) -> UInt32 {
        if let offset = stringOffsets[name] {
            return offset
        }
        let offset = UInt32(stringsBlock.count)
        stringsBlock.append(contentsOf: name.utf8)
        stringsBlock.append(0) // NUL
        stringOffsets[name] = offset
        return offset
    }

    // MARK: - Assembly

    private func assembleFDT() -> Data {
        // Finalize structure block with FDT_END token.
        appendU32(&structureBlock, FDT_END)

        // The FDT header is 40 bytes.
        let headerSize: UInt32 = 40
        // Memory reservation block: just one empty entry (16 bytes of zeros).
        let memRsvSize: UInt32 = 16
        let structOffset = headerSize + memRsvSize
        let stringsOffset = structOffset + UInt32(structureBlock.count)
        let totalSize = stringsOffset + UInt32(stringsBlock.count)

        var header = Data(count: Int(headerSize))
        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: FDT_MAGIC.bigEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: totalSize.bigEndian, toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: structOffset.bigEndian, toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: stringsOffset.bigEndian, toByteOffset: 12, as: UInt32.self)
            ptr.storeBytes(of: headerSize.bigEndian, toByteOffset: 16, as: UInt32.self) // off_mem_rsvmap
            ptr.storeBytes(of: FDT_VERSION.bigEndian, toByteOffset: 20, as: UInt32.self)
            ptr.storeBytes(of: FDT_LAST_COMP_VERSION.bigEndian, toByteOffset: 24, as: UInt32.self)
            ptr.storeBytes(of: UInt32(0).bigEndian, toByteOffset: 28, as: UInt32.self) // boot_cpuid_phys
            ptr.storeBytes(of: UInt32(stringsBlock.count).bigEndian, toByteOffset: 32, as: UInt32.self)
            ptr.storeBytes(of: UInt32(structureBlock.count).bigEndian, toByteOffset: 36, as: UInt32.self)
        }

        // Memory reservation block: one empty (terminator) entry.
        let memRsv = Data(count: Int(memRsvSize))

        var result = header
        result.append(memRsv)
        result.append(structureBlock)
        result.append(stringsBlock)

        return result
    }

    // MARK: - Binary Helpers

    private func appendU32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private func appendString(_ data: inout Data, _ string: String) {
        data.append(contentsOf: string.utf8)
        data.append(0) // NUL
    }

    private func alignTo4(_ data: inout Data) {
        let remainder = data.count % 4
        if remainder != 0 {
            data.append(contentsOf: [UInt8](repeating: 0, count: 4 - remainder))
        }
    }

    private func encodeU64Array(_ values: [UInt64]) -> Data {
        var data = Data(count: values.count * 8)
        data.withUnsafeMutableBytes { ptr in
            for (i, val) in values.enumerated() {
                ptr.storeBytes(of: val.bigEndian, toByteOffset: i * 8, as: UInt64.self)
            }
        }
        return data
    }
}
