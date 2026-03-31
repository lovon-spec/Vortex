// VirtioDeviceBaseTests.swift — Unit tests for VirtioDeviceBase.
// VortexDevicesTests

#if canImport(XCTest)
import Foundation
import XCTest
@testable import VortexCore
@testable import VortexDevices

// MARK: - Test Device Subclass

final class TestVirtioDevice: VirtioDeviceBase, @unchecked Sendable {
    var notifiedQueues: [Int] = []
    var activatedCount: Int = 0
    var resetCount: Int = 0
    var deviceConfigData: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

    init(type: VirtioDeviceType = .block, numQueues: Int = 2, features: UInt64 = 0) {
        super.init(
            deviceType: type, numQueues: numQueues,
            deviceFeatures: features, configSize: 8, defaultQueueSize: 16
        )
    }

    override func handleQueueNotification(queueIndex: Int) {
        notifiedQueues.append(queueIndex)
    }

    override func readDeviceConfig(offset: Int, size: Int) -> UInt32 {
        guard offset >= 0 && offset < deviceConfigData.count else { return 0 }
        var result: UInt32 = 0
        for i in 0..<min(size, deviceConfigData.count - offset) {
            result |= UInt32(deviceConfigData[offset + i]) << (i * 8)
        }
        return result
    }

    override func writeDeviceConfig(offset: Int, size: Int, value: UInt32) {
        guard offset >= 0 && offset < deviceConfigData.count else { return }
        for i in 0..<min(size, deviceConfigData.count - offset) {
            deviceConfigData[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8))
        }
    }

    override func deviceReset() {
        resetCount += 1
        notifiedQueues.removeAll()
    }

    override func deviceActivated() {
        activatedCount += 1
    }
}

// MARK: - VirtioDeviceBase Tests

final class VirtioDeviceBaseTests: XCTestCase {

    func testInitialization() {
        let device = TestVirtioDevice(type: .sound, numQueues: 4, features: 0)
        XCTAssertEqual(device.deviceType, .sound)
        XCTAssertEqual(device.numQueues, 4)
        XCTAssertEqual(device.deviceConfigSize, 8)
        XCTAssertNotEqual(device.deviceFeatures & VirtioFeature.version1, 0)
    }

    func testDeviceFeatureRead() {
        let device = TestVirtioDevice(features: VirtioFeature.eventIdx)
        device.attachGuestMemory(MockGuestMemory())

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceFeatureSelect, size: 4, value: 0)
        let low = device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceFeature, size: 4)
        XCTAssertNotEqual(low & (1 << 29), 0)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceFeatureSelect, size: 4, value: 1)
        let high = device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceFeature, size: 4)
        XCTAssertNotEqual(high & 1, 0)
    }

    func testDriverFeatureWrite() {
        let device = TestVirtioDevice(features: VirtioFeature.eventIdx)
        device.attachGuestMemory(MockGuestMemory())

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 0)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1 << 29)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 0)
        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4), 1 << 29)
    }

    func testFullInitSequence() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus.acknowledge.rawValue))
        let s1 = device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1)
        XCTAssertTrue(VirtioDeviceStatus(rawValue: UInt8(s1)).contains(.acknowledge))

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver]).rawValue))

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK]).rawValue))
        let s4 = device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1)
        XCTAssertTrue(VirtioDeviceStatus(rawValue: UInt8(s4)).contains(.featuresOK))

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK, .driverOK]).rawValue))
        XCTAssertEqual(device.activatedCount, 1)
    }

    func testFeaturesOKFails() {
        let device = TestVirtioDevice(features: 0)
        device.attachGuestMemory(MockGuestMemory())

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver]).rawValue))

        // Request unsupported feature bit 10.
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 0)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1 << 10)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK]).rawValue))
        let readback = device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1)
        XCTAssertFalse(VirtioDeviceStatus(rawValue: UInt8(readback)).contains(.featuresOK))
    }

    func testFeaturesOKRequiresVersion1() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver]).rawValue))

        // Don't set VERSION_1.
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 0)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 0)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 0)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK]).rawValue))
        let readback = device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1)
        XCTAssertFalse(VirtioDeviceStatus(rawValue: UInt8(readback)).contains(.featuresOK))
    }

    func testDeviceReset() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())
        bringToDriverOK(device: device)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1, value: 0)
        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1), 0)
        XCTAssertEqual(device.resetCount, 1)
    }

    func testNumQueues() {
        let device = TestVirtioDevice(numQueues: 4)
        device.attachGuestMemory(MockGuestMemory())
        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.numQueues, size: 2), 4)
    }

    func testQueueSelectAndProperties() {
        let device = TestVirtioDevice(numQueues: 2)
        device.attachGuestMemory(MockGuestMemory())

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueSelect, size: 2, value: 0)
        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.queueSize, size: 2), 16)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueDescLow, size: 4, value: 0x1000_0000)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueDescHigh, size: 4, value: 0x0000_0001)
        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.queueDescLow, size: 4), 0x1000_0000)
        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.queueDescHigh, size: 4), 0x0000_0001)

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueSelect, size: 2, value: 1)
        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.queueDescLow, size: 4), 0)
    }

    func testQueueEnable() {
        let device = TestVirtioDevice(numQueues: 1)
        device.attachGuestMemory(MockGuestMemory())

        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueSelect, size: 2, value: 0)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueDescLow, size: 4, value: 0x1000)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueAvailLow, size: 4, value: 0x2000)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueUsedLow, size: 4, value: 0x3000)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueEnable, size: 2, value: 1)

        XCTAssertEqual(device.readCommonConfig(offset: VirtioCommonCfgOffset.queueEnable, size: 2), 1)
        XCTAssertTrue(device.queues[0].isEnabled)
    }

    func testQueueNotification() {
        let device = TestVirtioDevice(numQueues: 3)
        device.attachGuestMemory(MockGuestMemory())
        bringToDriverOK(device: device)

        device.processNotification(queueIndex: 1)
        device.processNotification(queueIndex: 2)
        XCTAssertEqual(device.notifiedQueues, [1, 2])
    }

    func testNotificationBeforeDriverOK() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())
        device.processNotification(queueIndex: 0)
        XCTAssertTrue(device.notifiedQueues.isEmpty)
    }

    func testISRReadClear() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())
        device.signalUsedBuffers(queueIndex: 0)
        XCTAssertNotEqual(device.readAndClearISR() & 0x01, 0)
        XCTAssertEqual(device.readAndClearISR(), 0)
    }

    func testConfigChangeISR() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())
        device.signalConfigChange()
        XCTAssertNotEqual(device.readAndClearISR() & 0x02, 0)
    }

    func testDeviceConfigRead() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())
        XCTAssertEqual(device.readDeviceConfig(offset: 0, size: 4), 0x04030201)
    }

    func testDeviceConfigWrite() {
        let device = TestVirtioDevice()
        device.attachGuestMemory(MockGuestMemory())
        device.writeDeviceConfig(offset: 0, size: 4, value: 0xAABBCCDD)
        XCTAssertEqual(device.readDeviceConfig(offset: 0, size: 4), 0xAABBCCDD)
    }

    func testDeviceTypeIDs() {
        XCTAssertEqual(VirtioDeviceType.network.typeID, 1)
        XCTAssertEqual(VirtioDeviceType.block.typeID, 2)
        XCTAssertEqual(VirtioDeviceType.console.typeID, 3)
        XCTAssertEqual(VirtioDeviceType.entropy.typeID, 4)
        XCTAssertEqual(VirtioDeviceType.balloon.typeID, 5)
        XCTAssertEqual(VirtioDeviceType.filesystem.typeID, 9)
        XCTAssertEqual(VirtioDeviceType.gpu.typeID, 16)
        XCTAssertEqual(VirtioDeviceType.input.typeID, 18)
        XCTAssertEqual(VirtioDeviceType.socket.typeID, 19)
        XCTAssertEqual(VirtioDeviceType.sound.typeID, 25)
    }

    // MARK: - Helpers

    private func bringToDriverOK(device: VirtioDeviceBase) {
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus.acknowledge.rawValue))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver]).rawValue))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK]).rawValue))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.deviceStatus, size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK, .driverOK]).rawValue))
    }
}

#endif // canImport(XCTest)
