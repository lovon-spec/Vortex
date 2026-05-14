// VirtioBlockTests.swift -- Unit tests for virtio block request handling.
// VortexDevicesTests

#if canImport(XCTest)
import Foundation
import XCTest
@testable import VortexDevices

private final class InMemoryBlockStorageBackend: BlockStorageBackend, @unchecked Sendable {
    private var bytes: Data
    private let lock = NSLock()
    let isReadOnly: Bool
    private(set) var flushCount = 0
    private(set) var isClosed = false

    var capacityBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        UInt64(bytes.count)
    }

    init(bytes: Data, isReadOnly: Bool = false) {
        self.bytes = bytes
        self.isReadOnly = isReadOnly
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        try validate(offset: offset, length: UInt64(length))
        lock.lock()
        defer { lock.unlock() }
        return bytes.subdata(in: Int(offset)..<Int(offset) + length)
    }

    func write(offset: UInt64, data: Data) throws {
        guard !isReadOnly else { throw BlockStorageError.readOnly }
        try validate(offset: offset, length: UInt64(data.count))
        lock.lock()
        defer { lock.unlock() }
        bytes.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushCount += 1
    }

    func close() {
        isClosed = true
    }

    func snapshot(offset: Int, length: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        bytes.subdata(in: offset..<offset + length)
    }

    private func validate(offset: UInt64, length: UInt64) throws {
        guard offset <= capacityBytes, length <= capacityBytes - offset else {
            throw BlockStorageError.outOfBounds(
                offset: offset,
                length: length,
                capacity: capacityBytes
            )
        }
    }
}

final class VirtioBlockTests: XCTestCase {
    private let baseGPA: UInt64 = 0x4000_0000

    func testGuestWriteRequestWritesBackendSector() {
        let backend = InMemoryBlockStorageBackend(bytes: Data(count: 1024))
        let (device, memory, layout) = makeConfiguredBlockDevice(backend: backend)

        let headerGPA = baseGPA + 0x20_000
        let dataGPA = baseGPA + 0x21_000
        let statusGPA = baseGPA + 0x22_000
        let payload = Data(repeating: 0xAB, count: Int(vortexBlockSectorSize))

        memory.write(at: headerGPA, data: requestHeader(type: 1, sector: 1))
        memory.write(at: dataGPA, data: payload)

        writeDescriptor(memory: memory, layout: layout, index: 0, addr: headerGPA, len: 16, flags: .next, next: 1)
        writeDescriptor(memory: memory, layout: layout, index: 1, addr: dataGPA, len: UInt32(payload.count), flags: .next, next: 2)
        writeDescriptor(memory: memory, layout: layout, index: 2, addr: statusGPA, len: 1, flags: .write, next: 0)
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.processNotification(queueIndex: 0)

        XCTAssertEqual(memory.read(at: statusGPA, size: 1).first, 0)
        XCTAssertEqual(backend.snapshot(offset: Int(vortexBlockSectorSize), length: payload.count), payload)
        XCTAssertEqual(memory.directReadUInt16(at: layout.usedRingMemOffset + 2), 1)
        XCTAssertEqual(memory.directReadUInt32(at: layout.usedRingMemOffset + 4), 0)
        XCTAssertEqual(memory.directReadUInt32(at: layout.usedRingMemOffset + 8), 1)
    }

    func testGuestReadRequestFillsWritableDescriptor() {
        var bytes = Data(count: 1024)
        let expected = Data((0..<Int(vortexBlockSectorSize)).map { UInt8($0 & 0xFF) })
        bytes.replaceSubrange(Int(vortexBlockSectorSize)..<Int(vortexBlockSectorSize) + expected.count, with: expected)
        let backend = InMemoryBlockStorageBackend(bytes: bytes)
        let (device, memory, layout) = makeConfiguredBlockDevice(backend: backend)

        let headerGPA = baseGPA + 0x30_000
        let dataGPA = baseGPA + 0x31_000
        let statusGPA = baseGPA + 0x32_000

        memory.write(at: headerGPA, data: requestHeader(type: 0, sector: 1))

        writeDescriptor(memory: memory, layout: layout, index: 0, addr: headerGPA, len: 16, flags: .next, next: 1)
        writeDescriptor(memory: memory, layout: layout, index: 1, addr: dataGPA, len: UInt32(expected.count), flags: [.next, .write], next: 2)
        writeDescriptor(memory: memory, layout: layout, index: 2, addr: statusGPA, len: 1, flags: .write, next: 0)
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.processNotification(queueIndex: 0)

        XCTAssertEqual(memory.read(at: dataGPA, size: expected.count), expected)
        XCTAssertEqual(memory.read(at: statusGPA, size: 1).first, 0)
        XCTAssertEqual(memory.directReadUInt32(at: layout.usedRingMemOffset + 8), UInt32(expected.count + 1))
    }

    func testGetIDRequestWritesPaddedSerial() {
        let backend = InMemoryBlockStorageBackend(bytes: Data(count: 1024))
        let serial = "VORTEX-TEST"
        let (device, memory, layout) = makeConfiguredBlockDevice(backend: backend, serial: serial)

        let headerGPA = baseGPA + 0x40_000
        let dataGPA = baseGPA + 0x41_000
        let statusGPA = baseGPA + 0x42_000

        memory.write(at: headerGPA, data: requestHeader(type: 8, sector: 0))

        writeDescriptor(memory: memory, layout: layout, index: 0, addr: headerGPA, len: 16, flags: .next, next: 1)
        writeDescriptor(memory: memory, layout: layout, index: 1, addr: dataGPA, len: 20, flags: [.next, .write], next: 2)
        writeDescriptor(memory: memory, layout: layout, index: 2, addr: statusGPA, len: 1, flags: .write, next: 0)
        postAvailable(memory: memory, layout: layout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.processNotification(queueIndex: 0)

        let idData = memory.read(at: dataGPA, size: 20)
        XCTAssertTrue(idData.starts(with: Data(serial.utf8)))
        XCTAssertEqual(idData.suffix(20 - serial.utf8.count), Data(repeating: 0, count: 20 - serial.utf8.count))
        XCTAssertEqual(memory.read(at: statusGPA, size: 1).first, 0)
    }

    func testConcurrentNotificationsProcessBlockQueueOnce() {
        let requestCount = 8
        let sectorSize = Int(vortexBlockSectorSize)
        var backing = Data(count: requestCount * sectorSize)
        for sector in 0..<requestCount {
            let payload = Data(repeating: UInt8(0xA0 + sector), count: sectorSize)
            backing.replaceSubrange(sector * sectorSize..<(sector + 1) * sectorSize, with: payload)
        }

        let backend = InMemoryBlockStorageBackend(bytes: backing)
        let (device, memory, layout) = makeConfiguredBlockDevice(backend: backend, queueSize: 64)
        var statusGPAs: [UInt64] = []
        var dataGPAs: [UInt64] = []

        for request in 0..<requestCount {
            let head = UInt16(request * 3)
            let headerGPA = baseGPA + 0x50_000 + UInt64(request) * 0x3000
            let dataGPA = headerGPA + 0x1000
            let statusGPA = headerGPA + 0x2000

            memory.write(at: headerGPA, data: requestHeader(type: 0, sector: UInt64(request)))
            writeDescriptor(memory: memory, layout: layout, index: head, addr: headerGPA, len: 16, flags: .next, next: head + 1)
            writeDescriptor(memory: memory, layout: layout, index: head + 1, addr: dataGPA, len: UInt32(sectorSize), flags: [.next, .write], next: head + 2)
            writeDescriptor(memory: memory, layout: layout, index: head + 2, addr: statusGPA, len: 1, flags: .write, next: 0)
            postAvailable(memory: memory, layout: layout, ringSlot: UInt16(request), headIndex: head, newAvailIdx: UInt16(request + 1))

            dataGPAs.append(dataGPA)
            statusGPAs.append(statusGPA)
        }

        DispatchQueue.concurrentPerform(iterations: requestCount) { _ in
            device.processNotification(queueIndex: 0)
        }

        XCTAssertEqual(memory.directReadUInt16(at: layout.usedRingMemOffset + 2), UInt16(requestCount))
        for request in 0..<requestCount {
            XCTAssertEqual(memory.read(at: statusGPAs[request], size: 1).first, 0)
            XCTAssertEqual(
                memory.read(at: dataGPAs[request], size: sectorSize),
                Data(repeating: UInt8(0xA0 + request), count: sectorSize)
            )
        }
    }

    private func makeConfiguredBlockDevice(
        backend: InMemoryBlockStorageBackend,
        serial: String = "VORTEX-TEST",
        queueSize: UInt16 = 16
    ) -> (VirtioBlockDevice, MockGuestMemory, TestQueueLayout) {
        let memory = MockGuestMemory(baseGPA: baseGPA, size: 1024 * 1024)
        let layout = TestQueueLayout(queueSize: queueSize, baseOffset: 0, baseGPA: baseGPA)
        let device = VirtioBlockDevice(backend: backend, serial: serial)

        device.attachGuestMemory(memory)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueSelect, size: 2, value: 0)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueDescLow, size: 4, value: UInt32(layout.descTableGPA))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueAvailLow, size: 4, value: UInt32(layout.availRingGPA))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueUsedLow, size: 4, value: UInt32(layout.usedRingGPA))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueEnable, size: 2, value: 1)
        bringToDriverOK(device)

        return (device, memory, layout)
    }

    private func bringToDriverOK(_ device: VirtioDeviceBase) {
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
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.driverFeature,
            size: 4,
            value: UInt32(truncatingIfNeeded: VirtioFeature.version1 >> 32)
        )
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
    }

    private func requestHeader(type: UInt32, sector: UInt64) -> Data {
        var data = Data(count: 16)
        data.storeLEUInt32(type, at: 0)
        data.storeLEUInt32(0, at: 4)
        data.storeLEUInt64(sector, at: 8)
        return data
    }
}

private extension Data {
    mutating func storeLEUInt32(_ value: UInt32, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            replaceSubrange(offset..<offset + 4, with: bytes)
        }
    }

    mutating func storeLEUInt64(_ value: UInt64, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            replaceSubrange(offset..<offset + 8, with: bytes)
        }
    }
}

#endif // canImport(XCTest)
