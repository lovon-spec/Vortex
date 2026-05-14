// VirtioEntropyTests.swift -- Unit tests for virtio-rng.
// VortexDevicesTests

#if canImport(XCTest)
import Foundation
import XCTest
@testable import VortexDevices

final class VirtioEntropyTests: XCTestCase {
    func testEntropyRequestFillsWritableBuffer() {
        let memory = MockGuestMemory()
        let layout = TestQueueLayout(queueSize: 4)
        let device = makeActivatedEntropyDevice(memory: memory, layout: layout)

        let outputGPA: UInt64 = 0x4000_8000
        writeDescriptor(
            memory: memory,
            layout: layout,
            index: 0,
            addr: outputGPA,
            len: 32,
            flags: .write,
            next: 0
        )
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.processNotification(queueIndex: 0)

        let usedElementOffset = layout.usedRingMemOffset + 4
        XCTAssertEqual(memory.directReadUInt32(at: usedElementOffset), 0)
        XCTAssertEqual(memory.directReadUInt32(at: usedElementOffset + 4), 32)
        XCTAssertEqual(memory.directReadUInt16(at: layout.usedRingMemOffset + 2), 1)

        let generated = memory.read(at: outputGPA, size: 32)
        XCTAssertEqual(generated.count, 32)
        XCTAssertTrue(generated.contains { $0 != 0 })
    }

    func testEntropyRequestWritesAcrossDescriptorChain() {
        let memory = MockGuestMemory()
        let layout = TestQueueLayout(queueSize: 4)
        let device = makeActivatedEntropyDevice(memory: memory, layout: layout)

        let firstGPA: UInt64 = 0x4000_9000
        let secondGPA: UInt64 = 0x4000_A000
        writeDescriptor(
            memory: memory,
            layout: layout,
            index: 0,
            addr: firstGPA,
            len: 8,
            flags: [.write, .next],
            next: 1
        )
        writeDescriptor(
            memory: memory,
            layout: layout,
            index: 1,
            addr: secondGPA,
            len: 24,
            flags: .write,
            next: 0
        )
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.processNotification(queueIndex: 0)

        let usedElementOffset = layout.usedRingMemOffset + 4
        XCTAssertEqual(memory.directReadUInt32(at: usedElementOffset + 4), 32)
        XCTAssertEqual(memory.read(at: firstGPA, size: 8).count, 8)
        XCTAssertEqual(memory.read(at: secondGPA, size: 24).count, 24)
    }

    private func makeActivatedEntropyDevice(
        memory: MockGuestMemory,
        layout: TestQueueLayout
    ) -> VirtioEntropyDevice {
        let device = VirtioEntropyDevice(defaultQueueSize: layout.queueSize)
        device.attachGuestMemory(memory)

        let queue = device.queues[0]
        queue.setDescriptorTable(address: layout.descTableGPA)
        queue.setAvailRing(address: layout.availRingGPA)
        queue.setUsedRing(address: layout.usedRingGPA)
        queue.enable()

        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.deviceStatus,
            size: 1,
            value: UInt32(VirtioDeviceStatus.acknowledge.rawValue)
        )
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.deviceStatus,
            size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver]).rawValue)
        )
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1)
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.deviceStatus,
            size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK]).rawValue)
        )
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.deviceStatus,
            size: 1,
            value: UInt32(VirtioDeviceStatus([.acknowledge, .driver, .featuresOK, .driverOK]).rawValue)
        )
        return device
    }
}

#endif // canImport(XCTest)
