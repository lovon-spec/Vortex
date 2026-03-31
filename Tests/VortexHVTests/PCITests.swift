// PCITests.swift -- Unit tests for PCI bus, config space, BAR allocation, and MSI-X.
// VortexHVTests

import Testing
import Foundation
@testable import VortexHV

// MARK: - Mock PCI Device

/// A minimal PCI device for testing.
final class MockPCIDevice: PCIDeviceEmulation, @unchecked Sendable {
    var configSpace: PCIConfigSpace
    var bars: [BARInfo]

    /// Records of BAR reads: (bar, offset, size).
    var barReads: [(bar: Int, offset: UInt64, size: Int)] = []
    /// Records of BAR writes: (bar, offset, size, value).
    var barWrites: [(bar: Int, offset: UInt64, size: Int, value: UInt64)] = []
    /// Whether didAllocateBARs was called.
    var barsAllocated = false

    init(
        vendorID: UInt16 = PCIVendorID.redHat,
        deviceID: UInt16 = 0x1040,
        bars: [BARInfo] = []
    ) {
        self.configSpace = PCIConfigSpace(
            vendorID: vendorID,
            deviceID: deviceID,
            classCode: 0x02,        // Network
            subclass: 0x00,
            subsystemVendorID: vendorID,
            subsystemID: 0x0001
        )
        self.bars = bars
    }

    func readBAR(bar: Int, offset: UInt64, size: Int) -> UInt64 {
        barReads.append((bar, offset, size))
        return 0xDEAD_BEEF
    }

    func writeBAR(bar: Int, offset: UInt64, size: Int, value: UInt64) {
        barWrites.append((bar, offset, size, value))
    }

    func didAllocateBARs() {
        barsAllocated = true
    }
}

// MARK: - PCIConfigSpace Tests

@Suite("PCIConfigSpace")
struct PCIConfigSpaceTests {

    @Test("Identity fields are set correctly")
    func initializationWithIdentity() {
        let config = PCIConfigSpace(
            vendorID: 0x1AF4,
            deviceID: 0x1040,
            revisionID: 0x01,
            classCode: 0x02,
            subclass: 0x00,
            progIF: 0x00,
            subsystemVendorID: 0x1AF4,
            subsystemID: 0x0001,
            interruptPin: 0x01
        )

        #expect(config.vendorID == 0x1AF4)
        #expect(config.deviceID == 0x1040)
        #expect(config.revisionID == 0x01)
        #expect(config.classCode == 0x02)
        #expect(config.subclass == 0x00)
        #expect(config.progIF == 0x00)
        #expect(config.headerType == 0x00) // Type 0
        #expect(config.subsystemVendorID == 0x1AF4)
        #expect(config.subsystemID == 0x0001)
        #expect(config.interruptPin == 0x01)
        // Status should have capabilities list bit set.
        #expect(config.status & PCIStatusRegister.capabilitiesList.rawValue != 0)
    }

    @Test("Raw byte access read/write round-trips")
    func rawByteAccess() {
        var config = PCIConfigSpace()
        config.write8(at: 0, value: 0xAA)
        #expect(config.read8(at: 0) == 0xAA)

        config.write16(at: 4, value: 0xBEEF)
        #expect(config.read16(at: 4) == 0xBEEF)

        config.write32(at: 8, value: 0xDEAD_BEEF)
        #expect(config.read32(at: 8) == 0xDEAD_BEEF)
    }

    @Test("Data stored in little-endian byte order")
    func littleEndianLayout() {
        var config = PCIConfigSpace()
        config.write32(at: 0, value: 0x04030201)
        #expect(config.data[0] == 0x01)
        #expect(config.data[1] == 0x02)
        #expect(config.data[2] == 0x03)
        #expect(config.data[3] == 0x04)
    }

    @Test("BAR accessors read and write correctly for all 6 BARs")
    func barAccessors() {
        var config = PCIConfigSpace()
        for i in 0..<6 {
            config.setBarValue(at: i, value: UInt32(0x1000 * (i + 1)))
            #expect(config.barValue(at: i) == UInt32(0x1000 * (i + 1)))
        }
    }

    @Test("Out-of-bounds reads return default values")
    func outOfBoundsReturnsDefault() {
        let config = PCIConfigSpace()
        #expect(config.read8(at: 256) == 0xFF)
        #expect(config.read16(at: 255) == 0xFFFF)
        #expect(config.read32(at: 254) == 0xFFFF_FFFF)
    }
}

// MARK: - BARType Tests

@Suite("BARType")
struct BARTypeTests {

    @Test("Decode 32-bit memory BAR")
    func decodeMemory32() {
        let barVal: UInt32 = 0xF000_0000
        #expect(BARType.decode(barVal) == .memory32)
    }

    @Test("Decode 64-bit memory BAR")
    func decodeMemory64() {
        // Memory, 64-bit (type field bits [2:1] = 10b), prefetchable (bit 3).
        let barVal: UInt32 = 0xF000_000C
        #expect(BARType.decode(barVal) == .memory64)
    }

    @Test("Decode I/O BAR")
    func decodeIO() {
        let barVal: UInt32 = 0x0000_0001 // Bit 0 set = I/O
        #expect(BARType.decode(barVal) == .io)
    }
}

// MARK: - PCIAddress Tests

@Suite("PCIAddress")
struct PCIAddressTests {

    @Test("Decode ECAM offset into bus/device/function/register")
    func decode() {
        // Bus 0, Device 3, Function 2, Register 0x40.
        let offset: UInt64 = (0 << 20) | (3 << 15) | (2 << 12) | 0x40
        let addr = PCIAddress.decode(ecamOffset: offset)
        #expect(addr.bus == 0)
        #expect(addr.device == 3)
        #expect(addr.function == 2)
        #expect(addr.register == 0x40)
    }

    @Test("Encode and decode round-trip preserves all fields")
    func roundTrip() {
        let original = PCIAddress(bus: 1, device: 31, function: 7, register: 0xFFC)
        let encoded = original.ecamOffset
        let decoded = PCIAddress.decode(ecamOffset: encoded)
        #expect(decoded.bus == original.bus)
        #expect(decoded.device == original.device)
        #expect(decoded.function == original.function)
        #expect(decoded.register == original.register)
    }
}

// MARK: - PCIBus Tests

@Suite("PCIBus")
struct PCIBusTests {

    @Test("Add device at explicit slot")
    func addDeviceAtSlot() throws {
        let bus = PCIBus()
        let device = MockPCIDevice()
        try bus.addDevice(device, slot: 5, function: 0)

        #expect(bus.device(at: 5, function: 0) != nil)
        #expect(bus.device(at: 5, function: 1) == nil)
        #expect(bus.deviceCount == 1)
    }

    @Test("Add device at auto-allocated slots")
    func addDeviceAutoSlot() throws {
        let bus = PCIBus()
        let dev1 = MockPCIDevice()
        let dev2 = MockPCIDevice()

        let slot1 = try bus.addDevice(dev1)
        let slot2 = try bus.addDevice(dev2)

        #expect(slot1 == 0)
        #expect(slot2 == 1)
        #expect(bus.deviceCount == 2)
    }

    @Test("Adding to occupied slot throws slotOccupied error")
    func slotOccupiedError() throws {
        let bus = PCIBus()
        let dev1 = MockPCIDevice()
        let dev2 = MockPCIDevice()

        try bus.addDevice(dev1, slot: 3)
        #expect(throws: PCIError.self) {
            try bus.addDevice(dev2, slot: 3)
        }
    }

    @Test("Reading config of absent device returns all-ones")
    func configReadAbsentDevice() {
        let bus = PCIBus()
        let val = bus.readConfig(ecamOffset: 0, size: 4)
        #expect(val == 0xFFFF_FFFF)
    }

    @Test("Read vendor/device ID from config space")
    func configReadVendorDeviceID() throws {
        let bus = PCIBus()
        let device = MockPCIDevice(vendorID: 0x1AF4, deviceID: 0x1040)
        try bus.addDevice(device, slot: 0)

        // Read vendor ID (offset 0, 2 bytes) from slot 0.
        let vendorID = bus.readConfig(ecamOffset: 0, size: 2)
        #expect(vendorID == 0x1AF4)

        // Read device ID (offset 2, 2 bytes).
        let deviceID = bus.readConfig(ecamOffset: 2, size: 2)
        #expect(deviceID == 0x1040)

        // Read combined vendor+device as 32-bit.
        let combined = bus.readConfig(ecamOffset: 0, size: 4)
        #expect(combined == 0x1040_1AF4) // Little-endian: vendorID low, deviceID high
    }

    @Test("Config reads for bus != 0 return all-ones")
    func configReadNonZeroBus() {
        let bus = PCIBus()
        let offset: UInt64 = 1 << 20 // Bus 1
        let val = bus.readConfig(ecamOffset: offset, size: 4)
        #expect(val == 0xFFFF_FFFF)
    }

    @Test("Writing to read-only identity fields is ignored")
    func configWriteReadOnly() throws {
        let bus = PCIBus()
        let device = MockPCIDevice(vendorID: 0x1AF4, deviceID: 0x1040)
        try bus.addDevice(device, slot: 0)

        // Try to write vendor ID -- should be ignored.
        bus.writeConfig(ecamOffset: 0, size: 2, value: 0xBEEF)
        let vendorID = bus.readConfig(ecamOffset: 0, size: 2)
        #expect(vendorID == 0x1AF4) // Unchanged
    }

    @Test("32-bit BAR is allocated in the 32-bit MMIO window")
    func bar32Allocation() throws {
        let bus = PCIBus(
            mmio32Base: 0x2000_0000,
            mmio32Size: 0x1000_0000,
            mmio64Base: 0x80_0000_0000,
            mmio64Size: 0x80_0000_0000
        )

        let device = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x1000),
        ])
        try bus.addDevice(device, slot: 0)

        #expect(device.barsAllocated)
        #expect(bus.barMappings.count == 1)

        let mapping = bus.barMappings[0]
        #expect(mapping.gpa >= 0x2000_0000)
        #expect(mapping.gpa < 0x3000_0000)
        #expect(mapping.size == 0x1000)

        // BAR address in config space should match.
        let barVal = device.configSpace.barValue(at: 0)
        #expect(UInt64(barVal & 0xFFFF_FFF0) == mapping.gpa)
    }

    @Test("64-bit BAR is allocated in the 64-bit MMIO window")
    func bar64Allocation() throws {
        let bus = PCIBus(
            mmio32Base: 0x2000_0000,
            mmio32Size: 0x1000_0000,
            mmio64Base: 0x80_0000_0000,
            mmio64Size: 0x80_0000_0000
        )

        let device = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory64, size: 0x10_0000, prefetchable: true),
            BARInfo(index: 1, type: .memory64High, size: 0),
        ])
        try bus.addDevice(device, slot: 0)

        #expect(device.barsAllocated)
        #expect(bus.barMappings.count == 1) // Only one mapping for the pair

        let mapping = bus.barMappings[0]
        #expect(mapping.gpa >= 0x80_0000_0000)
        #expect(mapping.size == 0x10_0000)

        // Low BAR should have 64-bit type bit set.
        let barLow = device.configSpace.barValue(at: 0)
        #expect(barLow & 0x04 != 0) // 64-bit type
        #expect(barLow & 0x08 != 0) // Prefetchable

        // High BAR should have the upper 32 bits of the address.
        let barHigh = device.configSpace.barValue(at: 1)
        let fullAddr = UInt64(barHigh) << 32 | UInt64(barLow & 0xFFFF_FFF0)
        #expect(fullAddr == mapping.gpa)
    }

    @Test("BAR sizing protocol returns correct size mask")
    func barSizing() throws {
        let bus = PCIBus()
        let device = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x1000),
        ])
        try bus.addDevice(device, slot: 0)

        // Simulate guest BAR sizing: write all-ones to BAR0.
        device.writeConfig(offset: PCIConfigOffset.bar0, size: 4, value: 0xFFFF_FFFF)
        let sizeResponse = device.readConfig(offset: PCIConfigOffset.bar0, size: 4)

        // Mask off type bits and invert to get size.
        let masked = sizeResponse & 0xFFFF_FFF0
        let size = (~masked) &+ 1
        #expect(size == 0x1000) // 4 KiB
    }

    @Test("Multiple devices get non-overlapping BAR allocations")
    func multipleDeviceBARAllocation() throws {
        let bus = PCIBus(
            mmio32Base: 0x2000_0000,
            mmio32Size: 0x1000_0000,
            mmio64Base: 0x80_0000_0000,
            mmio64Size: 0x80_0000_0000
        )

        let dev1 = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x1000),
        ])
        let dev2 = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x2000),
        ])

        try bus.addDevice(dev1, slot: 0)
        try bus.addDevice(dev2, slot: 1)

        #expect(bus.barMappings.count == 2)

        let addr1 = bus.barMappings[0].gpa
        let size1 = bus.barMappings[0].size
        let addr2 = bus.barMappings[1].gpa
        #expect(addr2 >= addr1 + size1, "BAR allocations must not overlap")
    }

    @Test("BAR mapping lookup finds correct device and offset")
    func barMappingLookup() throws {
        let bus = PCIBus(
            mmio32Base: 0x2000_0000,
            mmio32Size: 0x1000_0000,
            mmio64Base: 0x80_0000_0000,
            mmio64Size: 0x80_0000_0000
        )

        let device = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x1000),
        ])
        try bus.addDevice(device, slot: 0)

        let mapping = bus.barMappings[0]
        let result = bus.findBARMapping(at: mapping.gpa + 0x100)
        #expect(result != nil)
        #expect(result?.offset == 0x100)
        #expect(result?.mapping.barIndex == 0)

        // Address outside any BAR.
        #expect(bus.findBARMapping(at: 0x1000_0000) == nil)
    }

    @Test("allDevices returns devices sorted by slot then function")
    func allDevicesOrdering() throws {
        let bus = PCIBus()
        let dev0 = MockPCIDevice(vendorID: 0x1AF4, deviceID: 0x1000)
        let dev1 = MockPCIDevice(vendorID: 0x1AF4, deviceID: 0x1001)

        try bus.addDevice(dev1, slot: 5)
        try bus.addDevice(dev0, slot: 2)

        let all = bus.allDevices
        #expect(all.count == 2)
        #expect(all[0].slot == 2)
        #expect(all[1].slot == 5)
    }
}

// MARK: - PCIHostBridge Tests

@Suite("PCIHostBridge")
struct PCIHostBridgeTests {

    @Test("ECAM read returns device identity")
    func ecamRead() throws {
        let bus = PCIBus()
        let bridge = PCIHostBridge(bus: bus)
        let device = MockPCIDevice(vendorID: 0x1AF4, deviceID: 0x1040)
        try bus.addDevice(device, slot: 0)

        // Slot 0, function 0, offset 0 -- vendor + device ID.
        let val = bridge.mmioRead(offset: 0, size: 4)
        #expect(UInt32(truncatingIfNeeded: val) == 0x1040_1AF4)
    }

    @Test("ECAM write updates config space")
    func ecamWrite() throws {
        let bus = PCIBus()
        let bridge = PCIHostBridge(bus: bus)
        let device = MockPCIDevice(vendorID: 0x1AF4, deviceID: 0x1040)
        try bus.addDevice(device, slot: 0)

        // Write command register through ECAM. Offset 4 = command.
        bridge.mmioWrite(offset: 4, size: 2, value: UInt64(PCICommandRegister.busMaster.rawValue))
        let cmd = device.configSpace.command
        #expect(cmd & PCICommandRegister.busMaster.rawValue != 0)
    }

    @Test("ECAM read for absent device returns all-ones")
    func ecamAbsentDevice() {
        let bus = PCIBus()
        let bridge = PCIHostBridge(bus: bus)

        // Slot 31, function 7 -- no device.
        let offset: UInt64 = (31 << 15) | (7 << 12)
        let val = bridge.mmioRead(offset: offset, size: 4)
        #expect(val == 0xFFFF_FFFF)
    }

    @Test("BAR MMIO regions are registered and route to devices")
    func barRegionRegistration() throws {
        let bus = PCIBus(
            mmio32Base: 0x2000_0000,
            mmio32Size: 0x1000_0000,
            mmio64Base: 0x80_0000_0000,
            mmio64Size: 0x80_0000_0000
        )
        let bridge = PCIHostBridge(bus: bus)
        let addressSpace = AddressSpace()

        // Register ECAM.
        try addressSpace.registerDevice(bridge)

        // Add a device with a BAR.
        let device = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x1000),
        ])
        try bus.addDevice(device, slot: 0)

        // Register BAR regions.
        try bridge.registerBARRegions(with: addressSpace)

        // Verify the BAR region can be found in the address space.
        let mapping = bus.barMappings[0]
        let found = addressSpace.findDevice(at: mapping.gpa + 0x10)
        #expect(found != nil)
    }

    @Test("BAR MMIO reads and writes are forwarded to the device")
    func barMMIOForwarding() throws {
        let bus = PCIBus(
            mmio32Base: 0x2000_0000,
            mmio32Size: 0x1000_0000,
            mmio64Base: 0x80_0000_0000,
            mmio64Size: 0x80_0000_0000
        )
        let bridge = PCIHostBridge(bus: bus)
        let addressSpace = AddressSpace()

        try addressSpace.registerDevice(bridge)

        let device = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x1000),
        ])
        try bus.addDevice(device, slot: 0)
        try bridge.registerBARRegions(with: addressSpace)

        let mapping = bus.barMappings[0]

        // Read from the BAR region via address space.
        let readVal = addressSpace.read(at: mapping.gpa + 0x20, size: 4)
        #expect(readVal == 0xDEAD_BEEF) // Our mock returns this.
        #expect(device.barReads.count == 1)
        #expect(device.barReads[0].offset == 0x20)

        // Write to the BAR region.
        addressSpace.write(at: mapping.gpa + 0x30, size: 4, value: 0x1234)
        #expect(device.barWrites.count == 1)
        #expect(device.barWrites[0].offset == 0x30)
        #expect(device.barWrites[0].value == 0x1234)
    }

    @Test("resolveBAR returns correct device, bar index, and offset")
    func resolveBAR() throws {
        let bus = PCIBus(
            mmio32Base: 0x2000_0000,
            mmio32Size: 0x1000_0000,
            mmio64Base: 0x80_0000_0000,
            mmio64Size: 0x80_0000_0000
        )
        let bridge = PCIHostBridge(bus: bus)

        let device = MockPCIDevice(bars: [
            BARInfo(index: 0, type: .memory32, size: 0x1000),
        ])
        try bus.addDevice(device, slot: 0)

        let mapping = bus.barMappings[0]
        let result = bridge.resolveBAR(gpa: mapping.gpa + 0x100)
        #expect(result != nil)
        #expect(result?.bar == 0)
        #expect(result?.offset == 0x100)
    }
}

// MARK: - MSI-X Tests

@Suite("MSIXController")
struct MSIXControllerTests {

    @Test("Table entry read/write round-trip")
    func tableReadWrite() {
        let cap = MSIXCapability(tableBAR: 0, tableOffset: 0, pbaBAR: 0, pbaOffset: 0x800, tableSize: 4)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)

        // Write message address low to vector 0.
        controller.writeTable(offset: 0x00, size: 4, value: 0x0C00_0000)
        controller.writeTable(offset: 0x04, size: 4, value: 0)
        controller.writeTable(offset: 0x08, size: 4, value: 64)
        controller.writeTable(offset: 0x0C, size: 4, value: 0)

        #expect(controller.readTable(offset: 0x00, size: 4) == 0x0C00_0000)
        #expect(controller.readTable(offset: 0x04, size: 4) == 0)
        #expect(controller.readTable(offset: 0x08, size: 4) == 64)
        #expect(controller.readTable(offset: 0x0C, size: 4) == 0) // Unmasked
    }

    @Test("Vectors start masked by default")
    func vectorMasking() {
        let cap = MSIXCapability(tableBAR: 0, tableOffset: 0, pbaBAR: 0, pbaOffset: 0x800, tableSize: 4)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)

        // Vectors start masked.
        #expect(controller.readTable(offset: 0x0C, size: 4) == 1)

        // Unmask.
        controller.writeTable(offset: 0x0C, size: 4, value: 0)
        #expect(controller.readTable(offset: 0x0C, size: 4) == 0)

        // Mask again.
        controller.writeTable(offset: 0x0C, size: 4, value: 1)
        #expect(controller.readTable(offset: 0x0C, size: 4) == 1)
    }

    @Test("Capability structure is written into config space correctly")
    func capabilityInConfigSpace() {
        let cap = MSIXCapability(tableBAR: 1, tableOffset: 0x2000, pbaBAR: 1, pbaOffset: 0x3000, tableSize: 16)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)

        var configSpace = PCIConfigSpace(
            vendorID: 0x1AF4,
            deviceID: 0x1040,
            classCode: 0x02,
            subclass: 0x00
        )

        controller.writeCapabilityToConfigSpace(&configSpace, nextCapPointer: 0)

        // Cap ID = 0x11 (MSI-X).
        #expect(configSpace.read8(at: 0x40) == 0x11)
        // Next cap pointer = 0.
        #expect(configSpace.read8(at: 0x41) == 0)
        // Message control: table size = 15 (16 - 1).
        let msgCtrl = configSpace.read16(at: 0x42)
        #expect(msgCtrl & 0x07FF == 15)
        // Table offset/BIR: BAR 1, offset 0x2000.
        let tableOffsetBIR = configSpace.read32(at: 0x44)
        #expect(tableOffsetBIR & 0x7 == 1)         // BIR = 1
        #expect(tableOffsetBIR & 0xFFFF_FFF8 == 0x2000)
        // PBA offset/BIR.
        let pbaOffsetBIR = configSpace.read32(at: 0x48)
        #expect(pbaOffsetBIR & 0x7 == 1)            // BIR = 1
        #expect(pbaOffsetBIR & 0xFFFF_FFF8 == 0x3000)
        // Capabilities pointer should point to 0x40.
        #expect(configSpace.capabilitiesPointer == 0x40)
    }

    @Test("PBA is read-only -- writes are ignored")
    func pbaReadOnly() {
        let cap = MSIXCapability(tableBAR: 0, tableOffset: 0, pbaBAR: 0, pbaOffset: 0x800, tableSize: 4)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)

        #expect(controller.readPBA(offset: 0, size: 8) == 0)

        controller.writePBA(offset: 0, size: 8, value: 0xFFFF_FFFF_FFFF_FFFF)
        #expect(controller.readPBA(offset: 0, size: 8) == 0)
    }

    @Test("Enable and disable via config space write")
    func enableDisable() {
        let cap = MSIXCapability(tableBAR: 0, tableOffset: 0, pbaBAR: 0, pbaOffset: 0x800, tableSize: 4)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)

        #expect(!controller.isEnabled)

        // Enable MSI-X via config write to message control.
        _ = controller.writeConfigCapability(offset: 0x42, size: 2, value: UInt32(0x8000))
        #expect(controller.isEnabled)

        // Disable.
        _ = controller.writeConfigCapability(offset: 0x42, size: 2, value: 0)
        #expect(!controller.isEnabled)
    }

    @Test("vectorCount matches capability table size")
    func vectorCount() {
        let cap = MSIXCapability(tableBAR: 0, tableOffset: 0, pbaBAR: 0, pbaOffset: 0x800, tableSize: 32)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)
        #expect(controller.vectorCount == 32)
    }

    @Test("Config capability read returns enable and function mask state")
    func configCapabilityReadMessageControl() {
        let cap = MSIXCapability(tableBAR: 0, tableOffset: 0, pbaBAR: 0, pbaOffset: 0x800, tableSize: 8)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)

        // Enable MSI-X + function mask.
        let enableAndMask: UInt32 = 0xC000 // bits 15 + 14
        _ = controller.writeConfigCapability(offset: 0x42, size: 2, value: enableAndMask)

        let readBack = controller.readConfigCapability(offset: 0x42, size: 2)
        #expect(readBack != nil)
        #expect(readBack! & 0x07FF == 7) // Table size = 8-1
        #expect(readBack! & 0x8000 != 0) // Enable
        #expect(readBack! & 0x4000 != 0) // Function mask
    }

    @Test("Multiple vectors can be independently programmed")
    func multipleVectorTable() {
        let cap = MSIXCapability(tableBAR: 0, tableOffset: 0, pbaBAR: 0, pbaOffset: 0x1000, tableSize: 4)
        let controller = MSIXController(capability: cap, configOffset: 0x40, msiController: nil)

        // Program vector 2 (entry at offset 0x20 = 2 * 16).
        controller.writeTable(offset: 0x20, size: 4, value: 0xAAAA_0000)
        controller.writeTable(offset: 0x24, size: 4, value: 0x0000_0001)
        controller.writeTable(offset: 0x28, size: 4, value: 42)
        controller.writeTable(offset: 0x2C, size: 4, value: 0)

        #expect(controller.readTable(offset: 0x20, size: 4) == 0xAAAA_0000)
        #expect(controller.readTable(offset: 0x24, size: 4) == 0x0000_0001)
        #expect(controller.readTable(offset: 0x28, size: 4) == 42)
        #expect(controller.readTable(offset: 0x2C, size: 4) == 0)

        // Vector 0 should still be at defaults (masked).
        #expect(controller.readTable(offset: 0x0C, size: 4) == 1)
    }
}

// MARK: - Default Protocol Implementation Tests

@Suite("PCIDeviceEmulation default implementations")
struct DefaultConfigImplementationTests {

    @Test("Read-only fields are preserved after write attempts")
    func readOnlyFieldsPreserved() throws {
        let bus = PCIBus()
        let device = MockPCIDevice(vendorID: 0x1AF4, deviceID: 0x1040)
        try bus.addDevice(device, slot: 0)

        device.writeConfig(offset: PCIConfigOffset.vendorID, size: 2, value: 0xBEEF)
        device.writeConfig(offset: PCIConfigOffset.deviceID, size: 2, value: 0xDEAD)
        device.writeConfig(offset: PCIConfigOffset.revisionID, size: 1, value: 0xFF)
        device.writeConfig(offset: PCIConfigOffset.classCode, size: 1, value: 0xFF)
        device.writeConfig(offset: PCIConfigOffset.headerType, size: 1, value: 0xFF)

        #expect(device.readConfig(offset: PCIConfigOffset.vendorID, size: 2) == 0x1AF4)
        #expect(device.readConfig(offset: PCIConfigOffset.deviceID, size: 2) == 0x1040)
        #expect(device.readConfig(offset: PCIConfigOffset.classCode, size: 1) == 0x02)
        #expect(device.readConfig(offset: PCIConfigOffset.headerType, size: 1) == 0x00)
    }

    @Test("Command register is writable")
    func commandRegisterWritable() {
        let device = MockPCIDevice()
        device.writeConfig(offset: PCIConfigOffset.command, size: 2,
                          value: UInt32(PCICommandRegister.busMaster.rawValue | PCICommandRegister.memorySpace.rawValue))
        let cmd = device.readConfig(offset: PCIConfigOffset.command, size: 2)
        #expect(cmd & UInt32(PCICommandRegister.busMaster.rawValue) != 0)
        #expect(cmd & UInt32(PCICommandRegister.memorySpace.rawValue) != 0)
    }

    @Test("Interrupt line register is writable")
    func interruptLineWritable() {
        let device = MockPCIDevice()
        device.writeConfig(offset: PCIConfigOffset.interruptLine, size: 1, value: 10)
        #expect(device.readConfig(offset: PCIConfigOffset.interruptLine, size: 1) == 10)
    }
}
