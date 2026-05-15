// VirtioNetwork.swift -- VirtIO network device emulation.
// VortexDevices

import Foundation
import VortexCore

public protocol NetworkPacketBackend: AnyObject, Sendable {
    func start(onPacket: @escaping @Sendable (Data) -> Void) throws
    func send(packet: Data) throws
    func stop()
}

public enum NetworkPacketBackendError: Error, CustomStringConvertible {
    case startFailed(String)
    case sendFailed(String)
    case unsupportedMode(String)

    public var description: String {
        switch self {
        case .startFailed(let reason):
            return "Network backend start failed: \(reason)"
        case .sendFailed(let reason):
            return "Network packet send failed: \(reason)"
        case .unsupportedMode(let mode):
            return "Unsupported network mode for native backend: \(mode)"
        }
    }
}

private enum VirtioNetFeature {
    static let mtu: UInt64 = 1 << 3
    static let mac: UInt64 = 1 << 5
    static let mergeableRxBuffers: UInt64 = 1 << 15
    static let status: UInt64 = 1 << 16
}

private enum VirtioNetQueue {
    static let receive = 0
    static let transmit = 1
    static let count = 2
}

private enum VirtioNetConfigOffset {
    static let mac = 0
    static let status = 6
    static let maxVirtqueuePairs = 8
    static let mtu = 10
    static let size = 12
}

private let virtioNetBaseHeaderSize = 10
private let virtioNetMergeableRxHeaderSize = 12

/// Minimal modern virtio-net device backed by a host packet source.
///
/// The device intentionally starts with the common Linux-compatible baseline:
/// a single RX queue, a single TX queue, a fixed MAC address, link status, and
/// no checksum/segmentation offloads. That keeps packet ownership explicit in
/// Vortex while leaving room to negotiate offloads later.
public final class VirtioNetworkDevice: VirtioDeviceBase, @unchecked Sendable {
    public let macAddress: [UInt8]
    public let mtu: UInt16

    private let backend: any NetworkPacketBackend
    private let lock = NSLock()
    private var pendingReceivePackets: [Data] = []
    private var backendStarted = false

    public init(
        backend: any NetworkPacketBackend,
        macAddress: [UInt8],
        mtu: UInt16 = 1500
    ) {
        precondition(macAddress.count == 6, "MAC address must contain exactly 6 bytes.")
        self.backend = backend
        self.macAddress = macAddress
        self.mtu = mtu

        super.init(
            deviceType: .network,
            numQueues: VirtioNetQueue.count,
            deviceFeatures: VirtioNetFeature.mtu
                | VirtioNetFeature.mac
                | VirtioNetFeature.mergeableRxBuffers
                | VirtioNetFeature.status,
            configSize: VirtioNetConfigOffset.size,
            defaultQueueSize: 256
        )
    }

    public override func readDeviceConfig(offset: Int, size: Int) -> UInt32 {
        let bytes = configBytes()
        guard offset >= 0, offset < bytes.count else { return 0 }

        var value: UInt32 = 0
        let count = min(size, bytes.count - offset, 4)
        for index in 0..<count {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    public override func handleQueueNotification(queueIndex: Int) {
        lock.lock()
        defer { lock.unlock() }

        switch queueIndex {
        case VirtioNetQueue.receive:
            drainReceiveQueueLocked()
        case VirtioNetQueue.transmit:
            processTransmitQueueLocked()
        default:
            break
        }
    }

    public override func deviceActivated() {
        lock.lock()
        guard !backendStarted else {
            drainReceiveQueueLocked()
            lock.unlock()
            return
        }
        backendStarted = true
        lock.unlock()

        do {
            try backend.start { [weak self] packet in
                self?.receiveHostPacket(packet)
            }
        } catch {
            VortexLog.service.error("virtio-net backend failed to start: \(String(describing: error))")
        }
    }

    public override func deviceReset() {
        lock.lock()
        pendingReceivePackets.removeAll()
        let wasStarted = backendStarted
        backendStarted = false
        lock.unlock()

        if wasStarted {
            backend.stop()
        }
    }

    private func receiveHostPacket(_ packet: Data) {
        guard !packet.isEmpty else { return }

        lock.lock()
        pendingReceivePackets.append(packet)
        drainReceiveQueueLocked()
        lock.unlock()
    }

    private func processTransmitQueueLocked() {
        let txQueue = queues[VirtioNetQueue.transmit]
        let headerSize = virtioNetHeaderSizeLocked()

        while let chain = txQueue.nextAvailableChain() {
            let request = readReadableData(from: chain)
            if request.count >= headerSize {
                let packet = request.dropFirst(headerSize)
                if !packet.isEmpty {
                    do {
                        try backend.send(packet: Data(packet))
                    } catch {
                        VortexLog.service.error("virtio-net send failed: \(String(describing: error))")
                    }
                }
            }
            txQueue.addUsed(headIndex: chain.headIndex, length: 0)
            signalUsedBuffers(queueIndex: VirtioNetQueue.transmit)
        }
    }

    private func drainReceiveQueueLocked() {
        let rxQueue = queues[VirtioNetQueue.receive]
        let header = receiveHeaderLocked()

        while !pendingReceivePackets.isEmpty,
              let chain = rxQueue.nextAvailableChain() {
            let packet = pendingReceivePackets.removeFirst()
            let payload = header + packet
            let written = writeWritableData(payload, to: chain)
            rxQueue.addUsed(headIndex: chain.headIndex, length: UInt32(written))
            signalUsedBuffers(queueIndex: VirtioNetQueue.receive)
        }
    }

    private func readReadableData(from chain: DescriptorChain) -> Data {
        var data = Data()
        for descriptor in chain where descriptor.isDeviceReadable {
            data.append(chain.readBuffer(descriptor))
        }
        return data
    }

    private func writeWritableData(_ data: Data, to chain: DescriptorChain) -> Int {
        var cursor = data.startIndex
        var written = 0

        for descriptor in chain where descriptor.isDeviceWritable {
            guard cursor < data.endIndex else { break }
            let available = min(Int(descriptor.len), data.distance(from: cursor, to: data.endIndex))
            guard available > 0 else { continue }
            let end = data.index(cursor, offsetBy: available)
            chain.writeBuffer(data.subdata(in: cursor..<end), to: descriptor)
            cursor = end
            written += available
        }
        return written
    }

    private func configBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: VirtioNetConfigOffset.size)
        for index in 0..<6 {
            bytes[VirtioNetConfigOffset.mac + index] = macAddress[index]
        }

        storeLE(UInt16(1), into: &bytes, at: VirtioNetConfigOffset.status) // VIRTIO_NET_S_LINK_UP
        storeLE(UInt16(1), into: &bytes, at: VirtioNetConfigOffset.maxVirtqueuePairs)
        storeLE(mtu, into: &bytes, at: VirtioNetConfigOffset.mtu)
        return bytes
    }

    private func virtioNetHeaderSizeLocked() -> Int {
        (driverFeatures & VirtioNetFeature.mergeableRxBuffers) != 0
            ? virtioNetMergeableRxHeaderSize
            : virtioNetBaseHeaderSize
    }

    private func receiveHeaderLocked() -> Data {
        var header = Data(repeating: 0, count: virtioNetHeaderSizeLocked())
        if header.count >= virtioNetMergeableRxHeaderSize {
            storeLE(UInt16(1), into: &header, at: virtioNetBaseHeaderSize)
        }
        return header
    }

    private func storeLE(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0x00ff)
        bytes[offset + 1] = UInt8((value >> 8) & 0x00ff)
    }

    private func storeLE(_ value: UInt16, into data: inout Data, at offset: Int) {
        guard offset >= 0, offset + 2 <= data.count else { return }
        data[offset] = UInt8(value & 0x00ff)
        data[offset + 1] = UInt8((value >> 8) & 0x00ff)
    }
}
