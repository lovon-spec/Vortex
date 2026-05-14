// PCIHostBridge.swift -- ECAM and BAR MMIO handler for the PCI bus.
// VortexHV
//
// The PCIHostBridge presents two kinds of MMIO regions to the guest:
//
// 1. **ECAM region** -- Memory-mapped PCI configuration space. Guest firmware
//    and OS enumerate PCI devices by reading/writing this region. Each device
//    gets a 4 KiB config space page addressed by bus/device/function.
//
// 2. **BAR windows** -- Accesses to PCI MMIO windows are decoded against the
//    devices' live BAR registers and forwarded to the owning PCIDeviceEmulation.
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

    /// PCI MMIO window devices registered with the address space.
    private let lock = NSLock()
    private var barWindowDevices: [PCIBARWindow] = []

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

    /// Register PCI MMIO windows with the address space.
    ///
    /// Call this after all devices have been added to the bus. The windows
    /// dispatch dynamically using the live BAR values programmed by firmware or
    /// the guest OS, so BAR sizing and reassignment keep working after boot.
    ///
    /// - Parameter addressSpace: The guest address space to register with.
    /// - Throws: If a region overlaps an existing registration.
    public func registerBARRegions(with addressSpace: AddressSpace) throws {
        lock.lock()
        // Remove local references for hot-plug or re-registration. AddressSpace
        // currently only supports removeAll(), and this method is called once
        // during platform setup.
        barWindowDevices.removeAll()
        lock.unlock()

        let windows = [
            PCIBARWindow(
                bus: bus,
                baseAddress: MachineMemoryMap.pciMmio32Base,
                regionSize: MachineMemoryMap.pciMmio32Size
            ),
            PCIBARWindow(
                bus: bus,
                baseAddress: MachineMemoryMap.pciMmio64Base,
                regionSize: MachineMemoryMap.pciMmio64Size
            ),
        ]

        for window in windows {
            lock.lock()
            barWindowDevices.append(window)
            lock.unlock()
            try addressSpace.registerDevice(window)
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

// MARK: - BAR MMIO Window

/// An MMIODevice that forwards reads/writes in a PCI MMIO aperture to the
/// device selected by the current BAR register values.
///
/// Firmware and operating systems commonly probe BAR sizes and then reprogram
/// BAR bases. Routing at the window level avoids stale per-BAR address
/// registrations after those writes.
public final class PCIBARWindow: MMIODevice, @unchecked Sendable {
    public let baseAddress: UInt64
    public let regionSize: UInt64

    private let bus: PCIBus

    init(bus: PCIBus, baseAddress: UInt64, regionSize: UInt64) {
        self.bus = bus
        self.baseAddress = baseAddress
        self.regionSize = regionSize
    }

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        let gpa = baseAddress + offset
        guard let (mapping, barOffset) = bus.findBARMapping(at: gpa) else {
            return size == 8 ? UInt64.max : (UInt64(1) << UInt64(size * 8)) - 1
        }
        return mapping.device.readBAR(bar: mapping.barIndex, offset: barOffset, size: size)
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        let gpa = baseAddress + offset
        guard let (mapping, barOffset) = bus.findBARMapping(at: gpa) else {
            return
        }
        mapping.device.writeBAR(bar: mapping.barIndex, offset: barOffset, size: size, value: value)
    }
}
