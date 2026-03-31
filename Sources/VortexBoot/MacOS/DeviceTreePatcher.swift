// DeviceTreePatcher.swift -- macOS-specific device tree construction and patching.
// VortexBoot
//
// The XNU kernel expects a device tree that describes the virtual hardware
// in Apple's proprietary format. While the underlying binary format is
// Flattened Device Tree (FDT), the node names, compatible strings, and
// property layouts differ significantly from Linux's standard device tree.
//
// This module builds a minimal device tree compatible with XNU's
// expectations on Apple Silicon VMs. It reuses VortexHV's DTBBuilder for
// the low-level FDT binary generation but constructs an Apple-flavored
// tree structure.

import Foundation
import VortexCore
import VortexHV

// MARK: - Device Tree Patcher Configuration

/// Configuration parameters for building a macOS-compatible device tree.
public struct MacDeviceTreeConfig: Sendable {
    /// Number of virtual CPUs.
    public let cpuCount: Int

    /// Guest RAM size in bytes.
    public let memorySize: UInt64

    /// Guest RAM base address.
    public let memoryBase: UInt64

    /// Boot arguments to pass to the XNU kernel via the chosen node.
    ///
    /// Common arguments include:
    /// - `serial=3`: Enable serial console output.
    /// - `-v`: Verbose boot.
    /// - `debug=0x14e`: Enable kernel debugging.
    public let bootArgs: String

    /// Platform identity for this macOS VM.
    public let platformIdentity: MacPlatformIdentity?

    /// The machine model string (e.g. "VirtualMac2,1").
    public let machineModel: String

    /// Board identifier string (e.g. "Mac-XXX").
    public let boardID: String

    /// Firmware version string.
    public let firmwareVersion: String

    public init(
        cpuCount: Int,
        memorySize: UInt64,
        memoryBase: UInt64 = MachineMemoryMap.ramBase,
        bootArgs: String = "",
        platformIdentity: MacPlatformIdentity? = nil,
        machineModel: String = "VirtualMac2,1",
        boardID: String = "Mac-2BD1B31983FE1663",
        firmwareVersion: String = "0.0.0"
    ) {
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.memoryBase = memoryBase
        self.bootArgs = bootArgs
        self.platformIdentity = platformIdentity
        self.machineModel = machineModel
        self.boardID = boardID
        self.firmwareVersion = firmwareVersion
    }
}

// MARK: - Device Tree Patcher

/// Builds and patches device trees for macOS guest VMs.
///
/// XNU expects a device tree that follows Apple's conventions rather than
/// the standard ARM Linux device tree format. Key differences include:
///
/// - The root compatible string uses Apple's machine model identifiers.
/// - CPU nodes use Apple-specific compatible strings and properties.
/// - The `chosen` node contains macOS-specific boot parameters such as
///   the machine serial number, board-id, and boot-args.
/// - Interrupt controller and timer descriptions use Apple's format.
///
/// This class constructs the minimal device tree required to get XNU
/// to enumerate CPUs, discover memory, and proceed with boot. Additional
/// device nodes (USB, storage, display) are added as the boot chain
/// investigation progresses.
///
/// ## Usage
/// ```swift
/// let patcher = DeviceTreePatcher()
/// let config = MacDeviceTreeConfig(cpuCount: 4, memorySize: 8 * 1024*1024*1024)
/// let dtbData = patcher.buildMacOSDeviceTree(config: config)
/// vm.loadData(dtbData, at: MachineMemoryMap.dtbAddress)
/// ```
///
/// ## Extension Points
///
/// The device tree will need to be extended as macOS boot research reveals
/// additional required nodes. Key areas likely to need additions:
/// - DART (Device Address Resolution Table / IOMMU) nodes
/// - Apple Interrupt Controller (AIC) instead of GICv3
/// - NVRAM / chosen properties for personalization
/// - PCIe root complex in Apple format
/// - Platform power management nodes
public final class DeviceTreePatcher: Sendable {

    public init() {}

    // MARK: - Build Complete Device Tree

    /// Builds a complete macOS-compatible FDT binary.
    ///
    /// - Parameter config: Device tree configuration parameters.
    /// - Returns: The FDT binary data, ready to be loaded into guest RAM.
    public func buildMacOSDeviceTree(config: MacDeviceTreeConfig) -> Data {
        // For macOS VMs we build the device tree from scratch using our
        // own FDT writer since DTBBuilder targets Linux-style trees.
        // We use the same low-level binary format (FDT spec v0.4) but
        // with Apple-specific node structure.
        let writer = FDTWriter()

        // Root node.
        writer.beginNode("")
        writer.addStringProperty("compatible", value: "Apple,\(config.machineModel)")
        writer.addStringProperty("model", value: config.machineModel)
        writer.addU32Property("#address-cells", value: 2)
        writer.addU32Property("#size-cells", value: 2)

        // chosen node -- boot parameters.
        buildChosenNode(writer: writer, config: config)

        // memory node.
        buildMemoryNode(writer: writer, config: config)

        // CPU nodes.
        buildCPUNodes(writer: writer, config: config)

        // Interrupt controller (placeholder -- may need AIC for macOS).
        buildInterruptControllerNode(writer: writer, config: config)

        // Timer node.
        buildTimerNode(writer: writer, config: config)

        // Platform device placeholders.
        // TODO: Add DART/IOMMU, ANS (storage), display pipeline as research progresses.

        writer.endNode() // root

        return writer.finalize()
    }

    // MARK: - Patch Existing Device Tree

    /// Patches an existing device tree extracted from an IPSW.
    ///
    /// When a device tree is available from the IPSW, we may need to
    /// patch specific properties (memory size, CPU count, boot-args)
    /// rather than building from scratch. This is the preferred approach
    /// when a suitable base device tree is available.
    ///
    /// - Parameters:
    ///   - existingDTB: The raw FDT binary data from the IPSW.
    ///   - config: The desired configuration to patch into the tree.
    /// - Returns: The patched FDT binary data.
    ///
    /// - Note: Full FDT patching requires parsing and rewriting the binary.
    ///   This is a placeholder that currently rebuilds from scratch.
    ///   Real patching will be implemented once we have confirmed working
    ///   IPSW device trees.
    public func patchDeviceTree(
        existingDTB: Data,
        config: MacDeviceTreeConfig
    ) -> Data {
        // TODO: Implement actual FDT parse-and-patch when we have confirmed
        // working IPSW device trees to base off of.
        // For now, build from scratch. This ensures we have a consistent
        // tree structure while the boot chain is under investigation.
        return buildMacOSDeviceTree(config: config)
    }

    // MARK: - Node Builders

    private func buildChosenNode(writer: FDTWriter, config: MacDeviceTreeConfig) {
        writer.beginNode("chosen")

        // Boot arguments.
        if !config.bootArgs.isEmpty {
            writer.addStringProperty("bootargs", value: config.bootArgs)
        }

        // Machine serial number placeholder.
        // XNU reads this from chosen/machine-serial-number.
        writer.addStringProperty("machine-serial-number", value: "VM000000000")

        // Board ID -- identifies the board type to macOS.
        writer.addStringProperty("board-id", value: config.boardID)

        // Product name for display purposes.
        writer.addStringProperty("product-name", value: "Vortex Virtual Machine")

        // Firmware version.
        writer.addStringProperty("firmware-version", value: config.firmwareVersion)

        // Platform identity data, if available.
        if let identity = config.platformIdentity {
            writer.addDataProperty(
                "hardware-model",
                value: identity.hardwareModelData
            )
            writer.addDataProperty(
                "machine-identifier",
                value: identity.machineIdentifierData
            )
        }

        // Random seed for the kernel's early entropy pool.
        var randomSeed = UInt64.random(in: UInt64.min...UInt64.max)
        let seedData = Data(bytes: &randomSeed, count: 8)
        writer.addDataProperty("random-seed", value: seedData)

        writer.endNode()
    }

    private func buildMemoryNode(writer: FDTWriter, config: MacDeviceTreeConfig) {
        let addrHex = String(config.memoryBase, radix: 16)
        writer.beginNode("memory@\(addrHex)")
        writer.addStringProperty("device_type", value: "memory")
        writer.addU64PairProperty("reg", high: config.memoryBase, low: config.memorySize)
        writer.endNode()
    }

    private func buildCPUNodes(writer: FDTWriter, config: MacDeviceTreeConfig) {
        writer.beginNode("cpus")
        writer.addU32Property("#address-cells", value: 2)
        writer.addU32Property("#size-cells", value: 0)

        for i in 0..<config.cpuCount {
            writer.beginNode("cpu@\(i)")
            writer.addStringProperty("device_type", value: "cpu")
            // Apple Silicon CPUs use arm,vN compatible strings.
            // For VM purposes, arm,arm-v8 is the standard.
            writer.addStringListProperty("compatible", values: [
                "apple,vortex",
                "arm,arm-v8"
            ])
            writer.addU32Property("reg", value: UInt32(i))

            // CPU enable method for secondary CPUs.
            // Apple uses spin-table or their own mechanism, but PSCI
            // is what our VMM implements.
            writer.addStringProperty("enable-method", value: "psci")

            // Performance state placeholder.
            writer.addU32Property("cpu-frequency", value: 3_200_000_000)

            writer.endNode()
        }

        writer.endNode() // cpus
    }

    private func buildInterruptControllerNode(
        writer: FDTWriter,
        config: MacDeviceTreeConfig
    ) {
        // macOS on real Apple Silicon uses AIC (Apple Interrupt Controller),
        // but for Hypervisor.framework VMs, GICv3 is what the framework
        // provides. We describe GICv3 here; if macOS requires AIC, this
        // node will need to be replaced.
        //
        // TODO: Investigate whether XNU on VMs expects AIC or GICv3.
        // Apple's VZ framework may provide a GICv3-compatible interface.
        let gicDistBase = MachineMemoryMap.gicDistributorBase
        let gicRedistBase = MachineMemoryMap.gicRedistributorBase
        let gicRedistSize = UInt64(config.cpuCount) * MachineMemoryMap.gicRedistributorPerCPUSize

        writer.beginNode("intc@\(String(gicDistBase, radix: 16))")
        writer.addStringListProperty("compatible", values: ["arm,gic-v3"])
        writer.addU32Property("#interrupt-cells", value: 3)
        writer.addU32Property("#address-cells", value: 2)
        writer.addU32Property("#size-cells", value: 2)
        writer.addEmptyProperty("interrupt-controller")
        writer.addU32Property("phandle", value: 1)

        // reg: [distributor base, size, redistributor base, size]
        let regData = encodeU64Array([
            gicDistBase, MachineMemoryMap.gicDistributorSize,
            gicRedistBase, gicRedistSize,
        ])
        writer.addDataProperty("reg", value: regData)
        writer.addEmptyProperty("ranges")

        writer.endNode()
    }

    private func buildTimerNode(writer: FDTWriter, config: MacDeviceTreeConfig) {
        writer.beginNode("timer")
        writer.addStringListProperty("compatible", values: ["arm,armv8-timer"])
        writer.addEmptyProperty("always-on")

        // GIC interrupt specifiers for ARM generic timers.
        // Format: type (0=SPI, 1=PPI), number, flags
        let interrupts: [UInt32] = [
            1, 13, 0xF08,  // Secure Physical Timer PPI
            1, 14, 0xF08,  // Non-secure Physical Timer PPI
            1, 11, 0xF08,  // Virtual Timer PPI
            1, 10, 0xF08,  // Hypervisor Timer PPI
        ]
        writer.addU32ArrayProperty("interrupts", values: interrupts)

        writer.endNode()
    }

    // MARK: - Helpers

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

// MARK: - FDT Writer

/// Low-level Flattened Device Tree binary writer.
///
/// This is a standalone FDT writer used by `DeviceTreePatcher` to build
/// macOS-specific device trees without depending on `DTBBuilder`'s
/// Linux-centric tree structure. The binary format is identical -- only
/// the tree content differs.
///
/// The FDT binary format consists of:
/// - A 40-byte header with magic, size, and offset fields.
/// - A memory reservation block (one empty terminator entry).
/// - A structure block containing node begin/end tokens and property tokens.
/// - A strings block containing all property name strings (deduplicated).
final class FDTWriter {
    // FDT magic and version constants.
    private static let magic: UInt32 = 0xD00D_FEED
    private static let version: UInt32 = 17
    private static let lastCompatibleVersion: UInt32 = 16

    // FDT structure tokens.
    private static let beginNode: UInt32 = 0x0000_0001
    private static let endNodeToken: UInt32 = 0x0000_0002
    private static let propToken: UInt32 = 0x0000_0003
    private static let endToken: UInt32 = 0x0000_0009

    private var structureBlock = Data()
    private var stringsBlock = Data()
    private var stringOffsets: [String: UInt32] = [:]

    init() {}

    // MARK: - Node Operations

    /// Begin a new device tree node.
    ///
    /// - Parameter name: Node name (e.g. "chosen", "cpu@0"). Use "" for root.
    func beginNode(_ name: String) {
        appendU32(Self.beginNode)
        appendNullTerminatedString(name)
        alignTo4()
    }

    /// End the current device tree node.
    func endNode() {
        appendU32(Self.endNodeToken)
    }

    // MARK: - Property Operations

    /// Add a property with raw data.
    func addDataProperty(_ name: String, value: Data) {
        let nameOffset = internString(name)
        appendU32(Self.propToken)
        appendU32(UInt32(value.count))
        appendU32(nameOffset)
        structureBlock.append(value)
        alignTo4()
    }

    /// Add a null-terminated string property.
    func addStringProperty(_ name: String, value: String) {
        var data = Data(value.utf8)
        data.append(0)
        addDataProperty(name, value: data)
    }

    /// Add a string list property (multiple null-terminated strings).
    func addStringListProperty(_ name: String, values: [String]) {
        var data = Data()
        for s in values {
            data.append(contentsOf: s.utf8)
            data.append(0)
        }
        addDataProperty(name, value: data)
    }

    /// Add a 32-bit unsigned integer property.
    func addU32Property(_ name: String, value: UInt32) {
        var data = Data(count: 4)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: value.bigEndian, as: UInt32.self)
        }
        addDataProperty(name, value: data)
    }

    /// Add an array of 32-bit unsigned integers.
    func addU32ArrayProperty(_ name: String, values: [UInt32]) {
        var data = Data(count: values.count * 4)
        data.withUnsafeMutableBytes { ptr in
            for (i, val) in values.enumerated() {
                ptr.storeBytes(of: val.bigEndian, toByteOffset: i * 4, as: UInt32.self)
            }
        }
        addDataProperty(name, value: data)
    }

    /// Add a 64-bit unsigned integer property.
    func addU64Property(_ name: String, value: UInt64) {
        var data = Data(count: 8)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: value.bigEndian, as: UInt64.self)
        }
        addDataProperty(name, value: data)
    }

    /// Add a pair of 64-bit values (commonly used for reg properties).
    func addU64PairProperty(_ name: String, high: UInt64, low: UInt64) {
        var data = Data(count: 16)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: high.bigEndian, toByteOffset: 0, as: UInt64.self)
            ptr.storeBytes(of: low.bigEndian, toByteOffset: 8, as: UInt64.self)
        }
        addDataProperty(name, value: data)
    }

    /// Add an empty (zero-length) property (used for boolean flags).
    func addEmptyProperty(_ name: String) {
        addDataProperty(name, value: Data())
    }

    // MARK: - Finalization

    /// Finalizes the FDT and returns the complete binary blob.
    ///
    /// After calling this method, the writer should not be used further.
    ///
    /// - Returns: Complete FDT binary data including header.
    func finalize() -> Data {
        // Terminate the structure block.
        appendU32(Self.endToken)

        // Calculate offsets.
        let headerSize: UInt32 = 40
        let memReservationSize: UInt32 = 16  // One empty entry (terminator).
        let structOffset = headerSize + memReservationSize
        let stringsOffset = structOffset + UInt32(structureBlock.count)
        let totalSize = stringsOffset + UInt32(stringsBlock.count)

        // Build header.
        var header = Data(count: Int(headerSize))
        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: Self.magic.bigEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: totalSize.bigEndian, toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: structOffset.bigEndian, toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: stringsOffset.bigEndian, toByteOffset: 12, as: UInt32.self)
            // Memory reservation map offset.
            ptr.storeBytes(of: headerSize.bigEndian, toByteOffset: 16, as: UInt32.self)
            ptr.storeBytes(of: Self.version.bigEndian, toByteOffset: 20, as: UInt32.self)
            ptr.storeBytes(of: Self.lastCompatibleVersion.bigEndian, toByteOffset: 24, as: UInt32.self)
            // Boot CPU physical ID.
            ptr.storeBytes(of: UInt32(0).bigEndian, toByteOffset: 28, as: UInt32.self)
            // Strings block size.
            ptr.storeBytes(of: UInt32(stringsBlock.count).bigEndian, toByteOffset: 32, as: UInt32.self)
            // Structure block size.
            ptr.storeBytes(of: UInt32(structureBlock.count).bigEndian, toByteOffset: 36, as: UInt32.self)
        }

        // Memory reservation block: one empty entry (16 zero bytes).
        let memReservation = Data(count: Int(memReservationSize))

        var result = header
        result.append(memReservation)
        result.append(structureBlock)
        result.append(stringsBlock)

        return result
    }

    // MARK: - Internal Helpers

    private func internString(_ name: String) -> UInt32 {
        if let offset = stringOffsets[name] {
            return offset
        }
        let offset = UInt32(stringsBlock.count)
        stringsBlock.append(contentsOf: name.utf8)
        stringsBlock.append(0)
        stringOffsets[name] = offset
        return offset
    }

    private func appendU32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { structureBlock.append(contentsOf: $0) }
    }

    private func appendNullTerminatedString(_ string: String) {
        structureBlock.append(contentsOf: string.utf8)
        structureBlock.append(0)
    }

    private func alignTo4() {
        let remainder = structureBlock.count % 4
        if remainder != 0 {
            structureBlock.append(contentsOf: [UInt8](repeating: 0, count: 4 - remainder))
        }
    }
}
