// VirtioTransportTests.swift — Unit tests for VirtioTransport (virtio-pci).
// VortexDevicesTests

#if canImport(XCTest)
import Foundation
import XCTest
@testable import VortexCore
@testable import VortexDevices
@testable import VortexHV

final class VirtioTransportTests: XCTestCase {
    private static let configBAR = 1
    private static let msixBAR = 4

    // MARK: - PCI Identity

    func testPCIIdentityBlock() {
        let device = TestVirtioDevice(type: .block)
        let transport = VirtioTransport(device: device)

        XCTAssertEqual(transport.configSpace.vendorID, 0x1AF4)
        XCTAssertEqual(transport.configSpace.deviceID, 0x1042)
        XCTAssertEqual(transport.configSpace.subsystemVendorID, 0x1AF4)
        XCTAssertEqual(transport.configSpace.subsystemID, 0x1100)
        XCTAssertEqual(transport.configSpace.revisionID, 1)
    }

    func testPCIIdentitySound() {
        let device = TestVirtioDevice(type: .sound, numQueues: 4)
        let transport = VirtioTransport(device: device)

        XCTAssertEqual(transport.configSpace.deviceID, 0x1059)
        XCTAssertEqual(transport.configSpace.subsystemID, 0x1100)
    }

    func testClassCode() {
        let blockTransport = VirtioTransport(device: TestVirtioDevice(type: .block))
        XCTAssertEqual(blockTransport.configSpace.classCode, 0x01)

        let netTransport = VirtioTransport(device: TestVirtioDevice(type: .network))
        XCTAssertEqual(netTransport.configSpace.classCode, 0x02)

        let sndTransport = VirtioTransport(device: TestVirtioDevice(type: .sound))
        XCTAssertEqual(sndTransport.configSpace.classCode, 0x04)
        XCTAssertEqual(sndTransport.configSpace.subclass, 0x01)
    }

    // MARK: - Config Space Reads

    func testConfigSpaceHeader() {
        let device = TestVirtioDevice(type: .block)
        let transport = VirtioTransport(device: device)

        let word0 = transport.readConfig(offset: 0x00, size: 4)
        XCTAssertEqual(UInt16(truncatingIfNeeded: word0), 0x1AF4)
        XCTAssertEqual(UInt16(truncatingIfNeeded: word0 >> 16), 0x1042)

        let rev = transport.readConfig(offset: 0x08, size: 1)
        XCTAssertEqual(rev, 1)

        let capPtr = transport.readConfig(offset: 0x34, size: 1)
        XCTAssertEqual(capPtr, 0x40)

        let status = transport.readConfig(offset: 0x06, size: 2)
        XCTAssertNotEqual(status & 0x0010, 0)
    }

    // MARK: - BAR Descriptors

    func testBARDescriptors() {
        let device = TestVirtioDevice(type: .block, numQueues: 2)
        let transport = VirtioTransport(device: device)

        XCTAssertEqual(transport.bars[0].type, .unused)

        XCTAssertEqual(transport.bars[1].type, .memory32)
        XCTAssertGreaterThanOrEqual(transport.bars[1].size, 4096)
        let configBarSize = transport.bars[1].size
        XCTAssertEqual(configBarSize & (configBarSize - 1), 0)

        XCTAssertEqual(transport.bars[2].type, .unused)
        XCTAssertEqual(transport.bars[3].type, .unused)

        XCTAssertEqual(transport.bars[4].type, .memory64)
        XCTAssertGreaterThanOrEqual(transport.bars[4].size, 16_384)

        XCTAssertEqual(transport.bars[5].type, .memory64High)
    }

    // MARK: - Config BAR Common Config

    func testConfigBarCommonConfigRead() {
        let device = TestVirtioDevice(type: .block, numQueues: 2)
        let transport = VirtioTransport(device: device)
        transport.attachGuestMemory(MockGuestMemory())

        let numQueues = transport.readBAR(bar: Self.configBAR, offset: UInt64(VirtioCommonCfgOffset.numQueues), size: 2)
        XCTAssertEqual(numQueues, 2)
    }

    func testConfigBarCommonConfigWrite() {
        let device = TestVirtioDevice(type: .block, numQueues: 2)
        let transport = VirtioTransport(device: device)
        transport.attachGuestMemory(MockGuestMemory())

        transport.writeBAR(bar: Self.configBAR, offset: UInt64(VirtioCommonCfgOffset.queueSelect), size: 2, value: 1)
        XCTAssertEqual(transport.readBAR(bar: Self.configBAR, offset: UInt64(VirtioCommonCfgOffset.queueSelect), size: 2), 1)
    }

    // MARK: - Config BAR ISR

    func testConfigBarISRRead() {
        let device = TestVirtioDevice(type: .block)
        let transport = VirtioTransport(device: device)
        transport.attachGuestMemory(MockGuestMemory())

        device.signalConfigChange()

        let layout = VirtioConfigBarLayout(numQueues: device.numQueues, deviceCfgSize: device.deviceConfigSize)
        let isr = transport.readBAR(bar: Self.configBAR, offset: UInt64(layout.isrOffset), size: 4)
        XCTAssertNotEqual(isr & 0x02, 0)
        XCTAssertEqual(transport.readBAR(bar: Self.configBAR, offset: UInt64(layout.isrOffset), size: 4), 0)
    }

    // MARK: - Config BAR Device Config

    func testConfigBarDeviceConfig() {
        let device = TestVirtioDevice(type: .block)
        let transport = VirtioTransport(device: device)
        transport.attachGuestMemory(MockGuestMemory())

        let layout = VirtioConfigBarLayout(numQueues: device.numQueues, deviceCfgSize: device.deviceConfigSize)
        XCTAssertEqual(transport.readBAR(bar: Self.configBAR, offset: UInt64(layout.deviceCfgOffset), size: 4), 0x04030201)

        transport.writeBAR(bar: Self.configBAR, offset: UInt64(layout.deviceCfgOffset), size: 4, value: 0x11223344)
        XCTAssertEqual(transport.readBAR(bar: Self.configBAR, offset: UInt64(layout.deviceCfgOffset), size: 4), 0x11223344)
    }

    // MARK: - Notification

    func testNotificationDoorbell() {
        let device = TestVirtioDevice(type: .block, numQueues: 3)
        let transport = VirtioTransport(device: device)
        transport.attachGuestMemory(MockGuestMemory())
        bringToDriverOK(transport: transport)

        let layout = VirtioConfigBarLayout(numQueues: device.numQueues, deviceCfgSize: device.deviceConfigSize)
        let doorbellOffset = layout.notifyOffset + 1 * Int(layout.notifyOffMultiplier)
        transport.writeBAR(bar: Self.configBAR, offset: UInt64(doorbellOffset), size: 2, value: 0)
        XCTAssertEqual(device.notifiedQueues, [1])
    }

    // MARK: - MSI-X Table

    func testMSIXTable() {
        let device = TestVirtioDevice(type: .block, numQueues: 2)
        let transport = VirtioTransport(device: device)

        transport.writeBAR(bar: Self.msixBAR, offset: 0, size: 4, value: 0x0C00_0000)
        XCTAssertEqual(transport.readBAR(bar: Self.msixBAR, offset: 0, size: 4), 0x0C00_0000)

        transport.writeBAR(bar: Self.msixBAR, offset: 8, size: 4, value: 64)
        XCTAssertEqual(transport.readBAR(bar: Self.msixBAR, offset: 8, size: 4), 64)

        XCTAssertEqual(transport.readBAR(bar: Self.msixBAR, offset: 12, size: 4) & 1, 1)  // Masked
        transport.writeBAR(bar: Self.msixBAR, offset: 12, size: 4, value: 0)
        XCTAssertEqual(transport.readBAR(bar: Self.msixBAR, offset: 12, size: 4) & 1, 0)  // Unmasked
    }

    // MARK: - Full Init

    func testFullInitThroughTransport() {
        let device = TestVirtioDevice(type: .network, numQueues: 2)
        let transport = VirtioTransport(device: device)
        transport.attachGuestMemory(MockGuestMemory())
        bringToDriverOK(transport: transport)
        XCTAssertEqual(device.activatedCount, 1)
    }

    // MARK: - PCI Capabilities

    func testCapabilitiesChain() {
        let device = TestVirtioDevice(type: .block, numQueues: 2)
        let transport = VirtioTransport(device: device)

        let capPtr = transport.readConfig(offset: 0x34, size: 1)
        XCTAssertEqual(capPtr, 0x40)

        var offset = Int(capPtr)
        var capCount = 0
        var foundMSIX = false
        var foundVendor = false

        while offset != 0 && capCount < 10 {
            let capID = transport.readConfig(offset: offset, size: 1) & 0xFF
            let nextPtr = transport.readConfig(offset: offset + 1, size: 1) & 0xFF
            if capID == 0x09 { foundVendor = true }
            if capID == 0x11 { foundMSIX = true }
            capCount += 1
            offset = Int(nextPtr)
        }

        XCTAssertEqual(capCount, 5)
        XCTAssertTrue(foundVendor)
        XCTAssertTrue(foundMSIX)
    }

    func testQEMUModernCapabilityBars() {
        let device = TestVirtioDevice(type: .block, numQueues: 2)
        let transport = VirtioTransport(device: device)

        var virtioCapBars: [UInt8: UInt8] = [:]
        var msixTableBIR: UInt8?
        var msixPBABIR: UInt8?
        var offset = Int(transport.readConfig(offset: 0x34, size: 1))
        var capCount = 0

        while offset != 0 && capCount < 10 {
            let capID = UInt8(truncatingIfNeeded: transport.readConfig(offset: offset, size: 1))
            let nextPtr = Int(transport.readConfig(offset: offset + 1, size: 1) & 0xFF)

            if capID == 0x09 {
                let cfgType = UInt8(truncatingIfNeeded: transport.readConfig(offset: offset + 3, size: 1))
                let bar = UInt8(truncatingIfNeeded: transport.readConfig(offset: offset + 4, size: 1))
                virtioCapBars[cfgType] = bar
            } else if capID == 0x11 {
                let tableOffsetBIR = transport.readConfig(offset: offset + 4, size: 4)
                let pbaOffsetBIR = transport.readConfig(offset: offset + 8, size: 4)
                msixTableBIR = UInt8(truncatingIfNeeded: tableOffsetBIR & 0x7)
                msixPBABIR = UInt8(truncatingIfNeeded: pbaOffsetBIR & 0x7)
            }

            capCount += 1
            offset = nextPtr
        }

        XCTAssertEqual(virtioCapBars[VirtioPCICapType.commonCfg.rawValue], UInt8(Self.configBAR))
        XCTAssertEqual(virtioCapBars[VirtioPCICapType.notifyCfg.rawValue], UInt8(Self.configBAR))
        XCTAssertEqual(virtioCapBars[VirtioPCICapType.isrCfg.rawValue], UInt8(Self.configBAR))
        XCTAssertEqual(virtioCapBars[VirtioPCICapType.deviceCfg.rawValue], UInt8(Self.configBAR))
        XCTAssertEqual(msixTableBIR, UInt8(Self.msixBAR))
        XCTAssertEqual(msixPBABIR, UInt8(Self.msixBAR))
    }

    func testQEMUModernBARConfigSizing() {
        let transport = VirtioTransport(device: TestVirtioDevice(type: .block, numQueues: 2))

        transport.writeConfig(offset: PCIConfigOffset.bar0, size: 4, value: 0xFFFF_FFFF)
        XCTAssertEqual(transport.readConfig(offset: PCIConfigOffset.bar0, size: 4), 0)

        transport.writeConfig(offset: PCIConfigOffset.bar1, size: 4, value: 0xFFFF_FFFF)
        let expectedConfigMask = UInt32(truncatingIfNeeded: ~(transport.bars[1].size - 1)) & 0xFFFF_FFF0
        XCTAssertEqual(transport.readConfig(offset: PCIConfigOffset.bar1, size: 4), expectedConfigMask)

        transport.writeConfig(offset: PCIConfigOffset.bar4, size: 4, value: 0xFFFF_FFFF)
        let expectedMSIXMask = (UInt32(truncatingIfNeeded: ~(transport.bars[4].size - 1)) & 0xFFFF_FFF0) | 0x0C
        XCTAssertEqual(transport.readConfig(offset: PCIConfigOffset.bar4, size: 4), expectedMSIXMask)

        transport.writeConfig(offset: PCIConfigOffset.bar5, size: 4, value: 0xFFFF_FFFF)
        let expectedMSIXHighMask = UInt32(truncatingIfNeeded: (~(transport.bars[4].size - 1)) >> 32)
        XCTAssertEqual(transport.readConfig(offset: PCIConfigOffset.bar5, size: 4), expectedMSIXHighMask)
    }

    // MARK: - Interrupt Delivery

    func testInterruptCallback() {
        let device = TestVirtioDevice(type: .block, numQueues: 1)
        let _ = VirtioTransport(device: device)
        device.attachGuestMemory(MockGuestMemory())

        var receivedQueue: Int?
        var receivedVector: UInt16?
        device.interruptHandler = { queue, vector in
            receivedQueue = queue
            receivedVector = vector
        }

        device.signalUsedBuffers(queueIndex: 0)
        XCTAssertEqual(receivedQueue, 0)
        XCTAssertEqual(receivedVector, 0xFFFF)
    }

    // MARK: - Config Write

    func testReadOnlyFields() {
        let device = TestVirtioDevice(type: .block)
        let transport = VirtioTransport(device: device)

        let originalVendor = transport.readConfig(offset: 0x00, size: 2)
        transport.writeConfig(offset: 0x00, size: 2, value: 0xBEEF)
        XCTAssertEqual(transport.readConfig(offset: 0x00, size: 2), originalVendor)
    }

    func testCommandRegister() {
        let device = TestVirtioDevice(type: .block)
        let transport = VirtioTransport(device: device)
        transport.writeConfig(offset: PCIConfigOffset.command, size: 2, value: 0x0007)
        XCTAssertEqual(transport.readConfig(offset: PCIConfigOffset.command, size: 2), 0x0007)
    }

    func testDidAllocateBARs() {
        let transport = VirtioTransport(device: TestVirtioDevice(type: .block))
        transport.didAllocateBARs()  // No crash = pass.
    }

    // MARK: - Helpers

    private func bringToDriverOK(transport: VirtioTransport) {
        let ccBase: UInt64 = 0
        transport.writeBAR(bar: Self.configBAR, offset: ccBase + UInt64(VirtioCommonCfgOffset.deviceStatus),
            size: 1, value: UInt64(VirtioDeviceStatus.acknowledge.rawValue))
        transport.writeBAR(bar: Self.configBAR, offset: ccBase + UInt64(VirtioCommonCfgOffset.deviceStatus),
            size: 1, value: UInt64(VirtioDeviceStatus([.acknowledge, .driver]).rawValue))
        transport.writeBAR(bar: Self.configBAR, offset: ccBase + UInt64(VirtioCommonCfgOffset.driverFeatureSelect),
            size: 4, value: 1)
        transport.writeBAR(bar: Self.configBAR, offset: ccBase + UInt64(VirtioCommonCfgOffset.driverFeature),
            size: 4, value: 1)
        transport.writeBAR(bar: Self.configBAR, offset: ccBase + UInt64(VirtioCommonCfgOffset.deviceStatus),
            size: 1, value: UInt64(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK]).rawValue))
        transport.writeBAR(bar: Self.configBAR, offset: ccBase + UInt64(VirtioCommonCfgOffset.deviceStatus),
            size: 1, value: UInt64(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK, .driverOK]).rawValue))
    }
}

#endif // canImport(XCTest)
