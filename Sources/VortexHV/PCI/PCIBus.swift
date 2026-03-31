// PCIBus.swift -- PCI bus manager with ECAM config space and BAR allocation.
// VortexHV
//
// Manages PCI devices on bus 0 (single-bus topology sufficient for embedded VMs).
// Handles ECAM (Enhanced Configuration Access Mechanism) config space decoding,
// BAR MMIO address allocation, and device lookup by slot/function.
//
// The PCIBus itself is not an MMIODevice -- the PCIHostBridge wraps it and
// registers the ECAM and BAR MMIO regions with the AddressSpace.

import Foundation

// MARK: - PCI Address

/// A decoded PCI address from an ECAM offset.
public struct PCIAddress: Sendable, CustomStringConvertible {
    /// Bus number (0-255). We only emulate bus 0.
    public let bus: Int
    /// Device number (0-31).
    public let device: Int
    /// Function number (0-7).
    public let function: Int
    /// Register byte offset within the 4 KiB config space.
    public let register: Int

    /// Encode back to an ECAM offset.
    public var ecamOffset: UInt64 {
        UInt64(bus) << 20 | UInt64(device) << 15 | UInt64(function) << 12 | UInt64(register)
    }

    /// Decode an ECAM byte offset into bus/device/function/register.
    public static func decode(ecamOffset: UInt64) -> PCIAddress {
        PCIAddress(
            bus: Int((ecamOffset >> 20) & 0xFF),
            device: Int((ecamOffset >> 15) & 0x1F),
            function: Int((ecamOffset >> 12) & 0x7),
            register: Int(ecamOffset & 0xFFF)
        )
    }

    public var description: String {
        String(format: "%02x:%02x.%x +0x%03x", bus, device, function, register)
    }
}

// MARK: - PCI Slot

/// A slot on the PCI bus, identified by device and function number.
private struct PCISlot: Hashable {
    let device: Int
    let function: Int
}

// MARK: - BAR Mapping

/// Tracks the MMIO mapping for a single BAR.
public struct BARMapping: Sendable {
    /// The PCI device that owns this BAR.
    public let device: any PCIDeviceEmulation
    /// BAR index (0-5).
    public let barIndex: Int
    /// Guest physical address of the BAR.
    public let gpa: UInt64
    /// Size of the BAR in bytes.
    public let size: UInt64
}

// MARK: - PCI Bus

/// PCI bus manager.
///
/// Maintains the set of attached PCI devices, allocates BAR MMIO addresses,
/// and dispatches ECAM config space accesses.
///
/// **Bus topology**: Single bus (bus 0) with up to 32 devices and 8 functions each.
/// This matches the typical embedded VM topology used by QEMU virt machine.
///
/// **Threading**: All methods acquire an internal lock and are safe to call
/// from any thread.
public final class PCIBus: @unchecked Sendable {
    /// Maximum number of devices on bus 0.
    public static let maxDevices: Int = 32
    /// Maximum number of functions per device.
    public static let maxFunctions: Int = 8

    // MARK: - MMIO Allocation State

    /// 32-bit MMIO window: current allocation pointer.
    private var mmio32Next: UInt64
    /// 32-bit MMIO window: end address (exclusive).
    private let mmio32End: UInt64
    /// 64-bit MMIO window: current allocation pointer.
    private var mmio64Next: UInt64
    /// 64-bit MMIO window: end address (exclusive).
    private let mmio64End: UInt64

    // MARK: - Device Registry

    /// Map from slot (device, function) to the PCI device.
    private var devices: [PCISlot: any PCIDeviceEmulation] = [:]

    /// All BAR mappings (used by the host bridge to route MMIO accesses).
    public private(set) var barMappings: [BARMapping] = []

    /// Next available slot for auto-allocation.
    private var nextAutoSlot: Int = 0

    private let lock = NSLock()

    // MARK: - Initialization

    /// Create a PCI bus with the given MMIO windows.
    ///
    /// - Parameters:
    ///   - mmio32Base: Start of the 32-bit MMIO window for BAR allocation.
    ///   - mmio32Size: Size of the 32-bit MMIO window.
    ///   - mmio64Base: Start of the 64-bit MMIO window for BAR allocation.
    ///   - mmio64Size: Size of the 64-bit MMIO window.
    public init(
        mmio32Base: UInt64 = MachineMemoryMap.pciMmio32Base,
        mmio32Size: UInt64 = MachineMemoryMap.pciMmio32Size,
        mmio64Base: UInt64 = MachineMemoryMap.pciMmio64Base,
        mmio64Size: UInt64 = MachineMemoryMap.pciMmio64Size
    ) {
        self.mmio32Next = mmio32Base
        self.mmio32End = mmio32Base + mmio32Size
        self.mmio64Next = mmio64Base
        self.mmio64End = mmio64Base + mmio64Size
    }

    // MARK: - Device Management

    /// Add a PCI device at a specific slot and function.
    ///
    /// After adding, BARs are allocated from the appropriate MMIO window and the
    /// BAR registers in config space are programmed with the allocated addresses.
    ///
    /// - Parameters:
    ///   - device: The PCI device to add.
    ///   - slot: Device number (0-31).
    ///   - function: Function number (0-7).
    /// - Throws: `PCIError.slotOccupied` if the slot is taken.
    public func addDevice(_ device: any PCIDeviceEmulation, slot: Int, function: Int = 0) throws {
        guard slot >= 0 && slot < PCIBus.maxDevices else {
            throw PCIError.busCapacityExceeded
        }
        guard function >= 0 && function < PCIBus.maxFunctions else {
            throw PCIError.busCapacityExceeded
        }

        let key = PCISlot(device: slot, function: function)

        lock.lock()

        if devices[key] != nil {
            lock.unlock()
            throw PCIError.slotOccupied(slot: slot, function: function)
        }

        devices[key] = device

        // Track the next auto-slot past any explicitly used ones.
        if slot >= nextAutoSlot {
            nextAutoSlot = slot + 1
        }

        lock.unlock()

        // Allocate BARs for the device.
        try allocateBARs(for: device)
    }

    /// Add a PCI device at the next available slot (function 0).
    ///
    /// - Parameter device: The PCI device to add.
    /// - Returns: The slot number that was assigned.
    /// - Throws: `PCIError.busCapacityExceeded` if no slots are available.
    @discardableResult
    public func addDevice(_ device: any PCIDeviceEmulation) throws -> Int {
        lock.lock()
        let slot = nextAutoSlot
        lock.unlock()

        guard slot < PCIBus.maxDevices else {
            throw PCIError.busCapacityExceeded
        }

        try addDevice(device, slot: slot, function: 0)
        return slot
    }

    /// Look up the device at a given slot and function.
    public func device(at slot: Int, function: Int) -> (any PCIDeviceEmulation)? {
        lock.lock()
        defer { lock.unlock() }
        return devices[PCISlot(device: slot, function: function)]
    }

    /// Get all registered devices.
    public var allDevices: [(slot: Int, function: Int, device: any PCIDeviceEmulation)] {
        lock.lock()
        defer { lock.unlock() }
        return devices.map { (slot: $0.key.device, function: $0.key.function, device: $0.value) }
            .sorted { ($0.slot, $0.function) < ($1.slot, $1.function) }
    }

    /// The number of registered devices.
    public var deviceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return devices.count
    }

    // MARK: - ECAM Config Space Access

    /// Read from the ECAM configuration space.
    ///
    /// - Parameters:
    ///   - offset: Byte offset from the ECAM base (encodes bus/device/function/register).
    ///   - size: Access width in bytes (1, 2, or 4).
    /// - Returns: The config space value, or all-ones if no device at the addressed slot.
    public func readConfig(ecamOffset: UInt64, size: Int) -> UInt32 {
        let addr = PCIAddress.decode(ecamOffset: ecamOffset)

        // We only emulate bus 0.
        guard addr.bus == 0 else {
            return allOnes(size: size)
        }

        lock.lock()
        let dev = devices[PCISlot(device: addr.device, function: addr.function)]
        lock.unlock()

        guard let device = dev else {
            // No device: return all-ones (standard PCI enumeration behavior).
            return allOnes(size: size)
        }

        return device.readConfig(offset: addr.register, size: size)
    }

    /// Write to the ECAM configuration space.
    ///
    /// - Parameters:
    ///   - offset: Byte offset from the ECAM base.
    ///   - size: Access width in bytes (1, 2, or 4).
    ///   - value: The value to write.
    public func writeConfig(ecamOffset: UInt64, size: Int, value: UInt32) {
        let addr = PCIAddress.decode(ecamOffset: ecamOffset)

        guard addr.bus == 0 else { return }

        lock.lock()
        let dev = devices[PCISlot(device: addr.device, function: addr.function)]
        lock.unlock()

        guard let device = dev else { return }

        device.writeConfig(offset: addr.register, size: size, value: value)
    }

    // MARK: - BAR MMIO Access

    /// Find the BAR mapping for a given guest physical address.
    ///
    /// - Parameter gpa: The guest physical address.
    /// - Returns: The BAR mapping and the offset within the BAR, or nil.
    public func findBARMapping(at gpa: UInt64) -> (mapping: BARMapping, offset: UInt64)? {
        lock.lock()
        defer { lock.unlock() }

        for mapping in barMappings {
            if gpa >= mapping.gpa && gpa < mapping.gpa + mapping.size {
                return (mapping, gpa - mapping.gpa)
            }
        }
        return nil
    }

    // MARK: - BAR Allocation

    /// Allocate a region from the 32-bit MMIO window.
    ///
    /// - Parameters:
    ///   - size: Size in bytes (must be a power of 2).
    ///   - alignment: Alignment requirement (must be a power of 2, typically == size).
    /// - Returns: The allocated guest physical address.
    /// - Throws: `PCIError.mmioAllocationFailed` if there is insufficient space.
    public func allocateMMIO(size: UInt64, alignment: UInt64) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        let alignMask = alignment - 1
        let aligned = (mmio32Next + alignMask) & ~alignMask

        guard aligned + size <= mmio32End else {
            throw PCIError.mmioAllocationFailed(size: size, alignment: alignment)
        }

        mmio32Next = aligned + size
        return aligned
    }

    /// Allocate a region from the 64-bit MMIO window (above 4 GiB).
    ///
    /// - Parameters:
    ///   - size: Size in bytes (must be a power of 2).
    ///   - alignment: Alignment requirement (must be a power of 2, typically == size).
    /// - Returns: The allocated guest physical address.
    /// - Throws: `PCIError.mmioAllocationFailed` if there is insufficient space.
    public func allocateMMIO64(size: UInt64, alignment: UInt64) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        let alignMask = alignment - 1
        let aligned = (mmio64Next + alignMask) & ~alignMask

        guard aligned + size <= mmio64End else {
            throw PCIError.mmioAllocationFailed(size: size, alignment: alignment)
        }

        mmio64Next = aligned + size
        return aligned
    }

    // MARK: - Private: BAR Setup

    /// Allocate MMIO ranges for all implemented BARs on a device and program them.
    private func allocateBARs(for device: any PCIDeviceEmulation) throws {
        var updatedBars = device.bars

        var barIndex = 0
        while barIndex < updatedBars.count {
            var bar = updatedBars[barIndex]

            guard bar.size > 0 && bar.type != .unused && bar.type != .memory64High else {
                barIndex += 1
                continue
            }

            // Alignment must be at least the BAR size (PCI spec requirement).
            let alignment = bar.size

            let allocatedAddress: UInt64
            switch bar.type {
            case .memory32:
                allocatedAddress = try allocateMMIO(size: bar.size, alignment: alignment)
            case .memory64:
                allocatedAddress = try allocateMMIO64(size: bar.size, alignment: alignment)
            case .io:
                // We do not emulate I/O port space on ARM64. Allocate from 32-bit MMIO.
                allocatedAddress = try allocateMMIO(size: bar.size, alignment: alignment)
            case .memory64High, .unused:
                barIndex += 1
                continue
            }

            bar.address = allocatedAddress
            updatedBars[barIndex] = bar

            // Program the BAR register in config space.
            switch bar.type {
            case .memory32:
                let barVal = UInt32(truncatingIfNeeded: allocatedAddress & 0xFFFF_FFF0)
                    | (bar.prefetchable ? 0x08 : 0x00)
                device.configSpace.setBarValue(at: barIndex, value: barVal)

            case .memory64:
                let barValLow = UInt32(truncatingIfNeeded: allocatedAddress & 0xFFFF_FFF0)
                    | 0x04 // 64-bit type
                    | (bar.prefetchable ? 0x08 : 0x00)
                device.configSpace.setBarValue(at: barIndex, value: barValLow)
                // High 32 bits in the next BAR.
                if barIndex + 1 < 6 {
                    let barValHigh = UInt32(truncatingIfNeeded: allocatedAddress >> 32)
                    device.configSpace.setBarValue(at: barIndex + 1, value: barValHigh)
                }

            case .io:
                let barVal = UInt32(truncatingIfNeeded: allocatedAddress & 0xFFFF_FFFC) | 0x01
                device.configSpace.setBarValue(at: barIndex, value: barVal)

            case .memory64High, .unused:
                break
            }

            // Record the BAR mapping for MMIO dispatch.
            lock.lock()
            barMappings.append(BARMapping(
                device: device,
                barIndex: barIndex,
                gpa: allocatedAddress,
                size: bar.size
            ))
            lock.unlock()

            // 64-bit BARs consume two BAR indices.
            if bar.type == .memory64 {
                barIndex += 2
            } else {
                barIndex += 1
            }
        }

        device.bars = updatedBars
        device.didAllocateBARs()
    }

    // MARK: - Helpers

    /// Return all-ones for the given access size (standard PCI behavior for absent devices).
    private func allOnes(size: Int) -> UInt32 {
        switch size {
        case 1: return 0xFF
        case 2: return 0xFFFF
        default: return 0xFFFF_FFFF
        }
    }
}
