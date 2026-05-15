// VirtioInputTests.swift -- Unit tests for virtio-input device emulation.
// VortexDevicesTests

#if canImport(XCTest)
import Foundation
import XCTest
@testable import VortexDevices

final class VirtioInputTests: XCTestCase {
    private let baseGPA: UInt64 = 0x4000_0000

    func testKeyboardConfigAcceptsCombinedSelectSubselectWrite() {
        let device = VirtioInputDevice(profile: .keyboard)

        writeConfigSelection(device, select: 0x11, subselect: 0x11) // EV_BITS / EV_LED

        XCTAssertEqual(device.readDeviceConfig(offset: 0, size: 1), 0x11)
        XCTAssertEqual(device.readDeviceConfig(offset: 1, size: 1), 0x11)
        XCTAssertEqual(device.readDeviceConfig(offset: 2, size: 1), 1)
        XCTAssertEqual(device.readDeviceConfig(offset: 8, size: 1), 0x07)
    }

    func testInputDeviceIDsMatchQEMUHIDProfiles() {
        let keyboard = VirtioInputDevice(profile: .keyboard)
        writeConfigSelection(keyboard, select: 0x03, subselect: 0x00) // ID_DEVIDS

        XCTAssertEqual(keyboard.readDeviceConfig(offset: 8, size: 2), 0x06)
        XCTAssertEqual(keyboard.readDeviceConfig(offset: 10, size: 2), 0x0627)
        XCTAssertEqual(keyboard.readDeviceConfig(offset: 12, size: 2), 0x0001)

        let tablet = VirtioInputDevice(profile: .tablet(width: 1280, height: 800))
        writeConfigSelection(tablet, select: 0x03, subselect: 0x00) // ID_DEVIDS

        XCTAssertEqual(tablet.readDeviceConfig(offset: 8, size: 2), 0x06)
        XCTAssertEqual(tablet.readDeviceConfig(offset: 10, size: 2), 0x0627)
        XCTAssertEqual(tablet.readDeviceConfig(offset: 12, size: 2), 0x0003)
    }

    func testKeyboardConfigAdvertisesRepeatEvents() {
        let device = VirtioInputDevice(profile: .keyboard)

        writeConfigSelection(device, select: 0x11, subselect: 0x14) // EV_BITS / EV_REP

        XCTAssertEqual(device.readDeviceConfig(offset: 2, size: 1), 1)
    }

    func testTabletConfigUsesQEMUCompatibleAbsoluteRange() {
        let device = VirtioInputDevice(profile: .tablet(width: 1280, height: 800))

        writeConfigSelection(device, select: 0x12, subselect: 0x00) // ABS_INFO / ABS_X

        XCTAssertEqual(device.readDeviceConfig(offset: 2, size: 1), 20)
        XCTAssertEqual(device.readDeviceConfig(offset: 8, size: 4), 0)
        XCTAssertEqual(device.readDeviceConfig(offset: 12, size: 4), 0x7fff)
    }

    func testTabletDoesNotAdvertiseDirectTouchProperty() {
        let device = VirtioInputDevice(profile: .tablet(width: 1280, height: 800))

        writeConfigSelection(device, select: 0x10, subselect: 0x00) // PROP_BITS

        XCTAssertEqual(device.readDeviceConfig(offset: 2, size: 1), 0)
    }

    func testKeyboardDropsEventsBeforeDriverOK() {
        let (device, memory, layout) = makeConfiguredDevice(profile: .keyboard)
        let eventGPA = baseGPA + 0x20_000

        writeDescriptor(
            memory: memory,
            layout: layout,
            index: 0,
            addr: eventGPA,
            len: 8,
            flags: .write,
            next: 0
        )
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.sendKey(code: 30, pressed: true)

        XCTAssertEqual(memory.directReadUInt16(at: layout.usedRingMemOffset + 2), 0)
        XCTAssertEqual(readInputEvent(memory: memory, gpa: eventGPA).type, 0)
    }

    func testKeyboardWritesKeyAndSyncEvents() {
        let (device, memory, layout) = makeConfiguredDevice(profile: .keyboard)
        setDriverOK(device)

        let keyGPA = baseGPA + 0x20_000
        let synGPA = baseGPA + 0x20_100
        writeWritableEventDescriptor(memory: memory, layout: layout, index: 0, gpa: keyGPA)
        writeWritableEventDescriptor(memory: memory, layout: layout, index: 1, gpa: synGPA)
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)
        postAvailable(memory: memory, layout: layout, ringSlot: 1, headIndex: 1, newAvailIdx: 2)

        device.sendKey(code: 30, pressed: true)

        XCTAssertEqual(memory.directReadUInt16(at: layout.usedRingMemOffset + 2), 2)
        XCTAssertEqual(readInputEvent(memory: memory, gpa: keyGPA), InputEvent(type: 0x01, code: 30, value: 1))
        XCTAssertEqual(readInputEvent(memory: memory, gpa: synGPA), InputEvent(type: 0x00, code: 0, value: 0))
    }

    func testTabletScalesPointerToAbsoluteInputRange() {
        let (device, memory, layout) = makeConfiguredDevice(profile: .tablet(width: 1280, height: 800))
        setDriverOK(device)

        let xGPA = baseGPA + 0x30_000
        let yGPA = baseGPA + 0x30_100
        let synGPA = baseGPA + 0x30_200
        writeWritableEventDescriptor(memory: memory, layout: layout, index: 0, gpa: xGPA)
        writeWritableEventDescriptor(memory: memory, layout: layout, index: 1, gpa: yGPA)
        writeWritableEventDescriptor(memory: memory, layout: layout, index: 2, gpa: synGPA)
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)
        postAvailable(memory: memory, layout: layout, ringSlot: 1, headIndex: 1, newAvailIdx: 2)
        postAvailable(memory: memory, layout: layout, ringSlot: 2, headIndex: 2, newAvailIdx: 3)

        device.sendTabletPointer(x: 1279, y: 799, buttons: [])

        XCTAssertEqual(memory.directReadUInt16(at: layout.usedRingMemOffset + 2), 3)
        XCTAssertEqual(readInputEvent(memory: memory, gpa: xGPA), InputEvent(type: 0x03, code: 0, value: 0x7fff))
        XCTAssertEqual(readInputEvent(memory: memory, gpa: yGPA), InputEvent(type: 0x03, code: 1, value: 0x7fff))
        XCTAssertEqual(readInputEvent(memory: memory, gpa: synGPA), InputEvent(type: 0x00, code: 0, value: 0))
    }

    private func writeConfigSelection(_ device: VirtioInputDevice, select: UInt8, subselect: UInt8) {
        let value = UInt32(select) | (UInt32(subselect) << 8)
        device.writeDeviceConfig(offset: 0, size: 2, value: value)
    }

    private func makeConfiguredDevice(
        profile: VirtioInputProfile
    ) -> (VirtioInputDevice, MockGuestMemory, TestQueueLayout) {
        let memory = MockGuestMemory()
        let layout = TestQueueLayout(queueSize: 16, baseOffset: 0x10_000, baseGPA: baseGPA)
        let device = VirtioInputDevice(profile: profile)
        device.attachGuestMemory(memory)

        let queue = device.queues[0]
        queue.setDescriptorTable(address: layout.descTableGPA)
        queue.setAvailRing(address: layout.availRingGPA)
        queue.setUsedRing(address: layout.usedRingGPA)
        queue.enable()

        return (device, memory, layout)
    }

    private func setDriverOK(_ device: VirtioInputDevice) {
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeature, size: 4, value: 1)
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.deviceStatus,
            size: 1,
            value: UInt32(VirtioDeviceStatus([
                .acknowledge,
                .driver,
                .featuresOK,
                .driverOK,
            ]).rawValue)
        )
    }

    private func writeWritableEventDescriptor(
        memory: MockGuestMemory,
        layout: TestQueueLayout,
        index: UInt16,
        gpa: UInt64
    ) {
        writeDescriptor(
            memory: memory,
            layout: layout,
            index: index,
            addr: gpa,
            len: 8,
            flags: .write,
            next: 0
        )
    }

    private struct InputEvent: Equatable {
        let type: UInt16
        let code: UInt16
        let value: Int32
    }

    private func readInputEvent(memory: MockGuestMemory, gpa: UInt64) -> InputEvent {
        let data = memory.read(at: gpa, size: 8)
        return InputEvent(
            type: data.leUInt16(at: 0),
            code: data.leUInt16(at: 2),
            value: Int32(bitPattern: data.leUInt32(at: 4))
        )
    }
}

private extension Data {
    func leUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func leUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
#endif
