// VirtQueueTests.swift — Unit tests for Virtio split virtqueue implementation.
// VortexDevicesTests

#if canImport(XCTest)
import Foundation
import XCTest
@testable import VortexDevices

// MARK: - Mock Guest Memory

/// A simple Data-backed guest memory accessor for testing.
final class MockGuestMemory: GuestMemoryAccessor, @unchecked Sendable {
    private var storage: [UInt8]
    let baseGPA: UInt64
    let size: Int

    init(baseGPA: UInt64 = 0x4000_0000, size: Int = 1024 * 1024) {
        self.baseGPA = baseGPA
        self.size = size
        self.storage = [UInt8](repeating: 0, count: size)
    }

    func read(at gpa: UInt64, size readSize: Int) -> Data {
        guard gpa >= baseGPA else { return Data(count: readSize) }
        let offset = Int(gpa - baseGPA)
        guard offset >= 0 && offset + readSize <= self.size else {
            return Data(count: readSize)
        }
        return Data(storage[offset..<offset + readSize])
    }

    func write(at gpa: UInt64, data: Data) {
        guard gpa >= baseGPA else { return }
        let offset = Int(gpa - baseGPA)
        guard offset >= 0 && offset + data.count <= self.size else { return }
        data.withUnsafeBytes { buf in
            let src = buf.bindMemory(to: UInt8.self)
            for i in 0..<src.count {
                storage[offset + i] = src[i]
            }
        }
    }

    func directWriteUInt16(at offset: Int, value: UInt16) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { buf in
            for i in 0..<2 { storage[offset + i] = buf[i] }
        }
    }

    func directWriteUInt32(at offset: Int, value: UInt32) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { buf in
            for i in 0..<4 { storage[offset + i] = buf[i] }
        }
    }

    func directWriteUInt64(at offset: Int, value: UInt64) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { buf in
            for i in 0..<8 { storage[offset + i] = buf[i] }
        }
    }

    func directReadUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        withUnsafeMutableBytes(of: &value) { buf in
            for i in 0..<2 { buf[i] = storage[offset + i] }
        }
        return UInt16(littleEndian: value)
    }

    func directReadUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { buf in
            for i in 0..<4 { buf[i] = storage[offset + i] }
        }
        return UInt32(littleEndian: value)
    }
}

// MARK: - Virtqueue Memory Layout Helper

struct TestQueueLayout {
    let queueSize: UInt16
    let baseOffset: Int
    let baseGPA: UInt64

    var descTableGPA: UInt64 { baseGPA + UInt64(baseOffset) }
    var descTableSize: Int { Int(queueSize) * VirtqDescriptor.size }
    var availRingGPA: UInt64 { descTableGPA + UInt64(descTableSize) }
    var availRingSize: Int { VirtQueue.availRingSize(queueSize: queueSize) }
    var usedRingGPA: UInt64 { availRingGPA + UInt64(availRingSize) }
    var usedRingSize: Int { VirtQueue.usedRingSize(queueSize: queueSize) }

    var descTableMemOffset: Int { baseOffset }
    var availRingMemOffset: Int { baseOffset + descTableSize }
    var usedRingMemOffset: Int { baseOffset + descTableSize + availRingSize }

    init(queueSize: UInt16 = 16, baseOffset: Int = 0, baseGPA: UInt64 = 0x4000_0000) {
        self.queueSize = queueSize
        self.baseOffset = baseOffset
        self.baseGPA = baseGPA
    }
}

// MARK: - Helpers

func writeDescriptor(
    memory: MockGuestMemory, layout: TestQueueLayout,
    index: UInt16, addr: UInt64, len: UInt32,
    flags: VirtqDescFlags, next: UInt16
) {
    let offset = layout.descTableMemOffset + Int(index) * VirtqDescriptor.size
    memory.directWriteUInt64(at: offset, value: addr)
    memory.directWriteUInt32(at: offset + 8, value: len)
    memory.directWriteUInt16(at: offset + 12, value: flags.rawValue)
    memory.directWriteUInt16(at: offset + 14, value: next)
}

func postAvailable(
    memory: MockGuestMemory, layout: TestQueueLayout,
    ringSlot: UInt16, headIndex: UInt16, newAvailIdx: UInt16
) {
    let entryOffset = layout.availRingMemOffset + 4 + Int(ringSlot) * 2
    memory.directWriteUInt16(at: entryOffset, value: headIndex)
    memory.directWriteUInt16(at: layout.availRingMemOffset + 2, value: newAvailIdx)
}

func setAvailFlags(memory: MockGuestMemory, layout: TestQueueLayout, flags: UInt16) {
    memory.directWriteUInt16(at: layout.availRingMemOffset, value: flags)
}

func makeEnabledQueue(mem: MockGuestMemory, layout: TestQueueLayout) -> VirtQueue {
    let queue = VirtQueue(index: 0, size: layout.queueSize, guestMemory: mem)
    queue.setDescriptorTable(address: layout.descTableGPA)
    queue.setAvailRing(address: layout.availRingGPA)
    queue.setUsedRing(address: layout.usedRingGPA)
    queue.enable()
    return queue
}

// MARK: - VirtQueue Tests

final class VirtQueueTests: XCTestCase {

    func testInitialization() {
        let mem = MockGuestMemory()
        let queue = VirtQueue(index: 0, size: 16, guestMemory: mem)

        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.queueSize, 16)
        XCTAssertFalse(queue.isEnabled)
        XCTAssertEqual(queue.descriptorTableAddress, 0)
        XCTAssertEqual(queue.availRingAddress, 0)
        XCTAssertEqual(queue.usedRingAddress, 0)
        XCTAssertEqual(queue.msixVector, 0xFFFF)
    }

    func testSetupAndEnable() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = VirtQueue(index: 0, size: layout.queueSize, guestMemory: mem)

        queue.setDescriptorTable(address: layout.descTableGPA)
        queue.setAvailRing(address: layout.availRingGPA)
        queue.setUsedRing(address: layout.usedRingGPA)
        queue.enable()

        XCTAssertTrue(queue.isEnabled)
        XCTAssertEqual(queue.descriptorTableAddress, layout.descTableGPA)
        XCTAssertEqual(queue.availRingAddress, layout.availRingGPA)
        XCTAssertEqual(queue.usedRingAddress, layout.usedRingGPA)
    }

    func testEnableRequiresAllAddresses() {
        let mem = MockGuestMemory()
        let queue = VirtQueue(index: 0, size: 16, guestMemory: mem)

        queue.setDescriptorTable(address: 0x1000)
        queue.enable()
        XCTAssertFalse(queue.isEnabled)

        queue.setAvailRing(address: 0x2000)
        queue.enable()
        XCTAssertFalse(queue.isEnabled)

        queue.setUsedRing(address: 0x3000)
        queue.enable()
        XCTAssertTrue(queue.isEnabled)
    }

    func testReset() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)
        XCTAssertTrue(queue.isEnabled)

        queue.reset()
        XCTAssertFalse(queue.isEnabled)
        XCTAssertEqual(queue.descriptorTableAddress, 0)
    }

    func testEmptyAvailableRing() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        XCTAssertFalse(queue.hasAvailable())
        XCTAssertNil(queue.nextAvailableChain())
    }

    func testSingleDescriptorChain() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        writeDescriptor(memory: mem, layout: layout, index: 0, addr: 0x4010_0000, len: 512, flags: [], next: 0)
        postAvailable(memory: mem, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        XCTAssertTrue(queue.hasAvailable())

        let chain = queue.nextAvailableChain()
        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.headIndex, 0)

        var descriptors: [VirtqDescriptor] = []
        if let chain = chain { for desc in chain { descriptors.append(desc) } }
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors[0].addr, 0x4010_0000)
        XCTAssertEqual(descriptors[0].len, 512)
        XCTAssertTrue(descriptors[0].isDeviceReadable)
        XCTAssertFalse(queue.hasAvailable())
    }

    func testChainedDescriptors() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        writeDescriptor(memory: mem, layout: layout, index: 0, addr: 0x4010_0000, len: 64, flags: .next, next: 1)
        writeDescriptor(memory: mem, layout: layout, index: 1, addr: 0x4010_1000, len: 4096, flags: .next, next: 2)
        writeDescriptor(memory: mem, layout: layout, index: 2, addr: 0x4010_2000, len: 1, flags: .write, next: 0)
        postAvailable(memory: mem, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        let chain = queue.nextAvailableChain()
        XCTAssertEqual(chain?.headIndex, 0)

        let readable = chain?.readableDescriptors ?? []
        let writable = chain?.writableDescriptors ?? []
        XCTAssertEqual(readable.count, 2)
        XCTAssertEqual(writable.count, 1)
        XCTAssertEqual(readable[0].len, 64)
        XCTAssertEqual(readable[1].len, 4096)
        XCTAssertTrue(writable[0].isDeviceWritable)
    }

    func testMultipleChains() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        writeDescriptor(memory: mem, layout: layout, index: 0, addr: 0x4010_0000, len: 256, flags: [], next: 0)
        writeDescriptor(memory: mem, layout: layout, index: 1, addr: 0x4010_1000, len: 512, flags: [], next: 0)
        postAvailable(memory: mem, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)
        postAvailable(memory: mem, layout: layout, ringSlot: 1, headIndex: 1, newAvailIdx: 2)

        XCTAssertEqual(queue.nextAvailableChain()?.headIndex, 0)
        XCTAssertEqual(queue.nextAvailableChain()?.headIndex, 1)
        XCTAssertNil(queue.nextAvailableChain())
    }

    func testAddUsed() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        queue.addUsed(headIndex: 3, length: 512)

        let elemOffset = layout.usedRingMemOffset + 4
        XCTAssertEqual(mem.directReadUInt32(at: elemOffset), 3)
        XCTAssertEqual(mem.directReadUInt32(at: elemOffset + 4), 512)
        XCTAssertEqual(mem.directReadUInt16(at: layout.usedRingMemOffset + 2), 1)
    }

    func testUsedRingWrapping() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout(queueSize: 4)
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        for i in 0..<5 {
            queue.addUsed(headIndex: UInt16(i % 4), length: UInt32(i * 100))
        }
        XCTAssertEqual(mem.directReadUInt16(at: layout.usedRingMemOffset + 2), 5)
    }

    func testNeedsNotificationDefault() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)
        XCTAssertTrue(queue.needsNotification())
    }

    func testNoInterruptFlag() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout()
        let queue = makeEnabledQueue(mem: mem, layout: layout)
        setAvailFlags(memory: mem, layout: layout, flags: VirtqAvailFlags.noInterrupt.rawValue)
        XCTAssertFalse(queue.needsNotification())
    }

    func testDisabledQueueNotification() {
        let mem = MockGuestMemory()
        let queue = VirtQueue(index: 0, size: 16, guestMemory: mem)
        XCTAssertFalse(queue.needsNotification())
    }

    func testDescriptorTableSize() {
        XCTAssertEqual(VirtQueue.descriptorTableSize(queueSize: 16), 16 * 16)
        XCTAssertEqual(VirtQueue.descriptorTableSize(queueSize: 256), 256 * 16)
    }

    func testAvailRingSize() {
        // flags(2) + idx(2) + ring[16]*2 + used_event(2) = 38
        XCTAssertEqual(VirtQueue.availRingSize(queueSize: 16), 38)
    }

    func testUsedRingSize() {
        // flags(2) + idx(2) + ring[16]*8 + avail_event(2) = 134
        XCTAssertEqual(VirtQueue.usedRingSize(queueSize: 16), 134)
    }

    func testLoopDetection() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout(queueSize: 4)
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        writeDescriptor(memory: mem, layout: layout, index: 0, addr: 0x4010_0000, len: 64, flags: .next, next: 1)
        writeDescriptor(memory: mem, layout: layout, index: 1, addr: 0x4010_1000, len: 64, flags: .next, next: 0)
        postAvailable(memory: mem, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        var count = 0
        if let chain = queue.nextAvailableChain() { for _ in chain { count += 1 } }
        XCTAssertLessThanOrEqual(count, 4)
    }

    func testOutOfBoundsNext() {
        let mem = MockGuestMemory()
        let layout = TestQueueLayout(queueSize: 4)
        let queue = makeEnabledQueue(mem: mem, layout: layout)

        writeDescriptor(memory: mem, layout: layout, index: 0, addr: 0x4010_0000, len: 64, flags: .next, next: 100)
        postAvailable(memory: mem, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        var count = 0
        if let chain = queue.nextAvailableChain() { for _ in chain { count += 1 } }
        XCTAssertEqual(count, 1)
    }
}

// MARK: - GuestMemoryAccessor Convenience Tests

final class GuestMemoryAccessorTests: XCTestCase {

    func testUInt16RoundTrip() {
        let mem = MockGuestMemory()
        mem.writeUInt16(at: 0x4000_0000, value: 0xBEEF)
        XCTAssertEqual(mem.readUInt16(at: 0x4000_0000), 0xBEEF)
    }

    func testUInt32RoundTrip() {
        let mem = MockGuestMemory()
        mem.writeUInt32(at: 0x4000_0100, value: 0xDEAD_BEEF)
        XCTAssertEqual(mem.readUInt32(at: 0x4000_0100), 0xDEAD_BEEF)
    }

    func testUInt64RoundTrip() {
        let mem = MockGuestMemory()
        mem.writeUInt64(at: 0x4000_0200, value: 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(mem.readUInt64(at: 0x4000_0200), 0x0123_4567_89AB_CDEF)
    }

    func testUnmappedRead() {
        let mem = MockGuestMemory(baseGPA: 0x4000_0000, size: 256)
        XCTAssertEqual(mem.readUInt32(at: 0x1000_0000), 0)
        XCTAssertEqual(mem.readUInt32(at: 0x4000_0000 + 300), 0)
    }
}

#endif // canImport(XCTest)
