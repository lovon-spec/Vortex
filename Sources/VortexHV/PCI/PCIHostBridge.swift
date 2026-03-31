// PCIHostBridge.swift -- ECAM and BAR MMIO handler for the PCI bus.
// VortexHV
//
// The PCIHostBridge presents two kinds of MMIO regions to the guest:
//
// 1. **ECAM region** -- Memory-mapped PCI configuration space. Guest firmware
//    and OS enumerate PCI devices by reading/writing this region. Each device
//    gets a 4 KiB config space page addressed by bus/device/function.
//
// 2. **BAR regions** -- When a device's BAR is allocated, accesses to the
//    BAR's GPA range are forwarded to the owning PCIDeviceEmulation.
//
// The host bridge registers itself as an MMIODevice for the ECAM region.
// For BAR MMIO, it manages a set of BARMMIORegion devices, each registered
// with the AddressSpace for one allocated BAR.

import Foundation

// MARK: - PCI Host Bridge

/// Top-level PCI host bridge that connects the PCI bus to the guest address space.
///
/// Handles:
/// - ECAM configuration space reads/writes (forwarded to PCIBus).
/// - BAR MMIO reads/writes (forwarded to the owning PCIDeviceEmulation).
///
/// **Usage**:
/// ```swift
/// let bus = PCIBus()
/// let bridge = PCIHostBridge(bus: bus)
/// try addressSpace.registerDevice(bridge)
///
/// // After adding devices:
/// try bus.addDevice(myDevice, slot: 0)
/// try bridge.registerBARRegions(with: addressSpace)
/// ```
///
/// **Threading**: All methods are thread-safe. MMIO callbacks are invoked from
/// vCPU threads.
public final class PCIHostBridge: MMIODevice, @unchecked Sendable {

    // MARK: - ECAM MMIO Properties

    /// ECAM base address in guest physical memory.
    public let baseAddress: UInt64

    /// ECAM region size.
    public let regionSize: UInt64

    /// The PCI bus this bridge manages.
    public let bus: PCIBus

    /// BAR MMIO region devices registered with the address space.
    /// One per allocated BAR.
    private let lock = NSLock()
    private var barRegionDevices: [BARMMIORegion] = []

    // MARK: - Initialization

    /// Create a PCI host bridge.
    ///
    /// - Parameters:
    ///   - bus: The PCI bus to bridge.
    ///   - ecamBase: The ECAM base address (from MachineMemoryMap).
    ///   - ecamSize: The ECAM region size.
    public init(
        bus: PCIBus,
        ecamBase: UInt64 = MachineMemoryMap.pciEcamBase,
        ecamSize: UInt64 = MachineMemoryMap.pciEcamSize
    ) {
        self.bus = bus
        self.baseAddress = ecamBase
        self.regionSize = ecamSize
    }

    // MARK: - ECAM MMIO Interface

    /// Handle a read from the ECAM config space region.
    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        // ECAM: the offset directly encodes bus/device/function/register.
        let value = bus.readConfig(ecamOffset: offset, size: size)
        return UInt64(value)
    }

    /// Handle a write to the ECAM config space region.
    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        bus.writeConfig(ecamOffset: offset, size: size, value: UInt32(truncatingIfNeeded: value))
    }

    // MARK: - BAR MMIO Registration

    /// Register MMIO regions for all allocated BARs with the address space.
    ///
    /// Call this after all devices have been added to the bus. Each BAR mapping
    /// gets its own `BARMMIORegion` device registered in the address space.
    ///
    /// - Parameter addressSpace: The guest address space to register with.
    /// - Throws: If a region overlaps an existing registration.
    public func registerBARRegions(with addressSpace: AddressSpace) throws {
        let mappings = bus.barMappings

        lock.lock()
        // Remove any previously registered BAR regions (for hot-plug or re-registration).
        barRegionDevices.removeAll()
        lock.unlock()

        for mapping in mappings {
            let region = BARMMIORegion(mapping: mapping)

            lock.lock()
            barRegionDevices.append(region)
            lock.unlock()

            try addressSpace.registerDevice(region)
        }
    }

    /// Look up which device and BAR a guest physical address belongs to.
    /// This is a convenience method that does not require going through the AddressSpace.
    public func resolveBAR(gpa: UInt64) -> (device: any PCIDeviceEmulation, bar: Int, offset: UInt64)? {
        guard let (mapping, offset) = bus.findBARMapping(at: gpa) else {
            return nil
        }
        return (mapping.device, mapping.barIndex, offset)
    }
}

// MARK: - BAR MMIO Region

/// An MMIODevice that forwards reads/writes to a PCI device's BAR handler.
///
/// One instance is created per allocated BAR and registered with the AddressSpace.
/// When the guest accesses a GPA within this BAR, the AddressSpace dispatches
/// to this device, which forwards to the owning PCIDeviceEmulation.
public final class BARMMIORegion: MMIODevice, @unchecked Sendable {
    public let baseAddress: UInt64
    public let regionSize: UInt64

    /// The PCI device that owns this BAR.
    private let device: any PCIDeviceEmulation
    /// The BAR index on the device.
    private let barIndex: Int

    init(mapping: BARMapping) {
        self.baseAddress = mapping.gpa
        self.regionSize = mapping.size
        self.device = mapping.device
        self.barIndex = mapping.barIndex
    }

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        device.readBAR(bar: barIndex, offset: offset, size: size)
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        device.writeBAR(bar: barIndex, offset: offset, size: size, value: value)
    }
}
