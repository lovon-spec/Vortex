// VirtioNetworkTests.swift -- Unit tests for virtio-net packet framing.
// VortexDevicesTests

#if canImport(XCTest)
import Foundation
import XCTest
@testable import VortexDevices

private enum TestVirtioNetFeature {
    static let mergeableRxBuffers: UInt64 = 1 << 15
}

private final class RecordingNetworkBackend: NetworkPacketBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var packetHandler: (@Sendable (Data) -> Void)?

    private(set) var started = false
    private(set) var sentPackets: [Data] = []

    func start(onPacket: @escaping @Sendable (Data) -> Void) throws {
        lock.lock()
        started = true
        packetHandler = onPacket
        lock.unlock()
    }

    func send(packet: Data) throws {
        lock.lock()
        sentPackets.append(packet)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        started = false
        packetHandler = nil
        lock.unlock()
    }

    func injectHostPacket(_ packet: Data) {
        lock.lock()
        let handler = packetHandler
        lock.unlock()
        handler?(packet)
    }
}

final class VirtioNetworkTests: XCTestCase {
    private let baseGPA: UInt64 = 0x4000_0000

    func testTransmitStripsMergeableRxBufferHeader() {
        let (device, backend, memory, _, txLayout) = makeConfiguredNetworkDevice(mergeableRxBuffers: true)
        let packet = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x52, 0x54, 0x00, 0x6f, 0x26, 0xb0]
        )
        let request = Data(repeating: 0, count: 12) + packet
        let requestGPA = baseGPA + 0x20_000

        memory.write(at: requestGPA, data: request)
        writeDescriptor(
            memory: memory,
            layout: txLayout,
            index: 0,
            addr: requestGPA,
            len: UInt32(request.count),
            flags: [],
            next: 0
        )
        postAvailable(memory: memory, layout: txLayout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.processNotification(queueIndex: 1)

        XCTAssertTrue(backend.started)
        XCTAssertEqual(backend.sentPackets, [packet])
        XCTAssertEqual(memory.directReadUInt16(at: txLayout.usedRingMemOffset + 2), 1)
    }

    func testTransmitStripsBaseHeaderWithoutMergeableRxBuffers() {
        let (device, backend, memory, _, txLayout) = makeConfiguredNetworkDevice(mergeableRxBuffers: false)
        let packet = ethernetFrame(
            destination: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            source: [0x52, 0x54, 0x00, 0x6f, 0x26, 0xb0]
        )
        let request = Data(repeating: 0, count: 10) + packet
        let requestGPA = baseGPA + 0x30_000

        memory.write(at: requestGPA, data: request)
        writeDescriptor(
            memory: memory,
            layout: txLayout,
            index: 0,
            addr: requestGPA,
            len: UInt32(request.count),
            flags: [],
            next: 0
        )
        postAvailable(memory: memory, layout: txLayout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        device.processNotification(queueIndex: 1)

        XCTAssertEqual(backend.sentPackets, [packet])
    }

    func testReceiveWritesMergeableRxBufferHeader() {
        let (_, backend, memory, rxLayout, _) = makeConfiguredNetworkDevice(mergeableRxBuffers: true)
        let packet = ethernetFrame(
            destination: [0x52, 0x54, 0x00, 0x6f, 0x26, 0xb0],
            source: [0xfe, 0xb2, 0x14, 0xdb, 0x96, 0x64]
        )
        let bufferGPA = baseGPA + 0x40_000

        writeDescriptor(
            memory: memory,
            layout: rxLayout,
            index: 0,
            addr: bufferGPA,
            len: UInt32(12 + packet.count),
            flags: .write,
            next: 0
        )
        postAvailable(memory: memory, layout: rxLayout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        backend.injectHostPacket(packet)

        let received = memory.read(at: bufferGPA, size: 12 + packet.count)
        XCTAssertEqual(received.prefix(10), Data(repeating: 0, count: 10))
        XCTAssertEqual(received.leUInt16(at: 10), 1)
        XCTAssertEqual(received.dropFirst(12), packet)
        XCTAssertEqual(memory.directReadUInt32(at: rxLayout.usedRingMemOffset + 8), UInt32(12 + packet.count))
    }

    func testReceiveWritesBaseHeaderWithoutMergeableRxBuffers() {
        let (_, backend, memory, rxLayout, _) = makeConfiguredNetworkDevice(mergeableRxBuffers: false)
        let packet = ethernetFrame(
            destination: [0x52, 0x54, 0x00, 0x6f, 0x26, 0xb0],
            source: [0xfe, 0xb2, 0x14, 0xdb, 0x96, 0x64]
        )
        let bufferGPA = baseGPA + 0x50_000

        writeDescriptor(
            memory: memory,
            layout: rxLayout,
            index: 0,
            addr: bufferGPA,
            len: UInt32(10 + packet.count),
            flags: .write,
            next: 0
        )
        postAvailable(memory: memory, layout: rxLayout, ringSlot: 0, headIndex: 0, newAvailIdx: 1)

        backend.injectHostPacket(packet)

        let received = memory.read(at: bufferGPA, size: 10 + packet.count)
        XCTAssertEqual(received.prefix(10), Data(repeating: 0, count: 10))
        XCTAssertEqual(received.dropFirst(10), packet)
    }

    private func makeConfiguredNetworkDevice(
        mergeableRxBuffers: Bool
    ) -> (VirtioNetworkDevice, RecordingNetworkBackend, MockGuestMemory, TestQueueLayout, TestQueueLayout) {
        let memory = MockGuestMemory(baseGPA: baseGPA, size: 1024 * 1024)
        let rxLayout = TestQueueLayout(queueSize: 16, baseOffset: 0x10_000, baseGPA: baseGPA)
        let txLayout = TestQueueLayout(queueSize: 16, baseOffset: 0x11_000, baseGPA: baseGPA)
        let backend = RecordingNetworkBackend()
        let device = VirtioNetworkDevice(
            backend: backend,
            macAddress: [0x52, 0x54, 0x00, 0x6f, 0x26, 0xb0]
        )

        XCTAssertNotEqual(device.deviceFeatures & TestVirtioNetFeature.mergeableRxBuffers, 0)

        device.attachGuestMemory(memory)
        configureQueue(device, index: 0, layout: rxLayout)
        configureQueue(device, index: 1, layout: txLayout)
        bringToDriverOK(device, mergeableRxBuffers: mergeableRxBuffers)

        return (device, backend, memory, rxLayout, txLayout)
    }

    private func configureQueue(_ device: VirtioNetworkDevice, index: UInt32, layout: TestQueueLayout) {
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueSelect, size: 2, value: index)
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueDescLow, size: 4, value: UInt32(layout.descTableGPA))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueAvailLow, size: 4, value: UInt32(layout.availRingGPA))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueUsedLow, size: 4, value: UInt32(layout.usedRingGPA))
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.queueEnable, size: 2, value: 1)
    }

    private func bringToDriverOK(_ device: VirtioNetworkDevice, mergeableRxBuffers: Bool) {
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

        var features = VirtioFeature.version1
        if mergeableRxBuffers {
            features |= TestVirtioNetFeature.mergeableRxBuffers
        }
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 0)
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.driverFeature,
            size: 4,
            value: UInt32(truncatingIfNeeded: features)
        )
        device.writeCommonConfig(offset: VirtioCommonCfgOffset.driverFeatureSelect, size: 4, value: 1)
        device.writeCommonConfig(
            offset: VirtioCommonCfgOffset.driverFeature,
            size: 4,
            value: UInt32(truncatingIfNeeded: features >> 32)
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

    private func ethernetFrame(destination: [UInt8], source: [UInt8]) -> Data {
        precondition(destination.count == 6)
        precondition(source.count == 6)
        var data = Data(destination)
        data.append(contentsOf: source)
        data.append(contentsOf: [0x08, 0x00])
        data.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
        return data
    }
}

private extension Data {
    func leUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }
}
#endif
