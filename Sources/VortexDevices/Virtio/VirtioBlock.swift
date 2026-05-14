// VirtioBlock.swift -- VirtIO block device emulation.
// VortexDevices

import Foundation

/// VirtIO block device backed by a ``BlockStorageBackend``.
public final class VirtioBlockDevice: VirtioDeviceBase, @unchecked Sendable {
    private enum RequestType: UInt32 {
        case `in` = 0
        case out = 1
        case flush = 4
        case getID = 8
    }

    private enum Status: UInt8 {
        case ok = 0
        case ioError = 1
        case unsupported = 2
    }

    private enum Feature {
        static let sizeMax: UInt64 = 1 << 1
        static let segMax: UInt64 = 1 << 2
        static let geometry: UInt64 = 1 << 4
        static let blkSize: UInt64 = 1 << 6
        static let flush: UInt64 = 1 << 9
    }

    private let backend: any BlockStorageBackend
    private let serial: String
    private let blockSize: UInt32

    public init(
        backend: any BlockStorageBackend,
        serial: String = "VORTEX-BLOCK",
        blockSize: UInt32 = UInt32(vortexBlockSectorSize)
    ) {
        self.backend = backend
        self.serial = serial
        self.blockSize = blockSize

        super.init(
            deviceType: .block,
            numQueues: 1,
            deviceFeatures: Feature.sizeMax
                | Feature.segMax
                | Feature.geometry
                | Feature.blkSize
                | Feature.flush,
            configSize: 60,
            defaultQueueSize: 256
        )
    }

    public override func handleQueueNotification(queueIndex: Int) {
        guard queueIndex == 0, queueIndex < queues.count else { return }
        let queue = queues[queueIndex]

        while let chain = queue.nextAvailableChain() {
            let written = process(chain: chain)
            queue.addUsed(headIndex: chain.headIndex, length: written)
            signalUsedBuffers(queueIndex: queueIndex)
        }
    }

    public override func readDeviceConfig(offset: Int, size: Int) -> UInt32 {
        let config = buildConfig()
        guard offset >= 0, offset < config.count else { return 0 }

        var value: UInt32 = 0
        let count = min(size, config.count - offset)
        for i in 0..<count {
            value |= UInt32(config[offset + i]) << (i * 8)
        }
        return value
    }

    public override func deviceReset() {
        try? backend.flush()
    }

    // MARK: - Request Processing

    private func process(chain: DescriptorChain) -> UInt32 {
        let descriptors = Array(chain)
        guard let headerDescriptor = descriptors.first,
              headerDescriptor.isDeviceReadable,
              headerDescriptor.len >= 16 else {
            writeStatus(.ioError, descriptors: descriptors, chain: chain)
            return 1
        }

        let header = chain.readBuffer(headerDescriptor)
        guard header.count >= 16 else {
            writeStatus(.ioError, descriptors: descriptors, chain: chain)
            return 1
        }

        let typeRaw = header.loadLEUInt32(at: 0)
        let sector = header.loadLEUInt64(at: 8)
        guard let requestType = RequestType(rawValue: typeRaw) else {
            writeStatus(.unsupported, descriptors: descriptors, chain: chain)
            return 1
        }

        do {
            switch requestType {
            case .in:
                let bytes = try processRead(sector: sector, descriptors: descriptors, chain: chain)
                writeStatus(.ok, descriptors: descriptors, chain: chain)
                return bytes + 1

            case .out:
                try processWrite(sector: sector, descriptors: descriptors, chain: chain)
                writeStatus(.ok, descriptors: descriptors, chain: chain)
                return 1

            case .flush:
                try backend.flush()
                writeStatus(.ok, descriptors: descriptors, chain: chain)
                return 1

            case .getID:
                let bytes = processGetID(descriptors: descriptors, chain: chain)
                writeStatus(.ok, descriptors: descriptors, chain: chain)
                return bytes + 1
            }
        } catch {
            writeStatus(.ioError, descriptors: descriptors, chain: chain)
            return 1
        }
    }

    private func processRead(
        sector: UInt64,
        descriptors: [VirtqDescriptor],
        chain: DescriptorChain
    ) throws -> UInt32 {
        let dataDescriptors = writableDataDescriptors(from: descriptors)
        let totalLength = dataDescriptors.reduce(0) { $0 + Int($1.len) }
        let offset = sector * vortexBlockSectorSize
        let data = try backend.read(offset: offset, length: totalLength)

        var cursor = 0
        for descriptor in dataDescriptors {
            let length = Int(descriptor.len)
            let chunk = data.subdata(in: cursor..<cursor + length)
            chain.writeBuffer(chunk, to: descriptor)
            cursor += length
        }

        return UInt32(totalLength)
    }

    private func processWrite(
        sector: UInt64,
        descriptors: [VirtqDescriptor],
        chain: DescriptorChain
    ) throws {
        let dataDescriptors = readableDataDescriptors(from: descriptors)
        var data = Data()
        for descriptor in dataDescriptors {
            data.append(chain.readBuffer(descriptor))
        }
        try backend.write(offset: sector * vortexBlockSectorSize, data: data)
    }

    private func processGetID(descriptors: [VirtqDescriptor], chain: DescriptorChain) -> UInt32 {
        guard let descriptor = writableDataDescriptors(from: descriptors).first else { return 0 }
        var data = Data(serial.utf8.prefix(Int(descriptor.len)))
        if data.count < descriptor.len {
            data.append(Data(repeating: 0, count: Int(descriptor.len) - data.count))
        }
        chain.writeBuffer(data, to: descriptor)
        return UInt32(data.count)
    }

    private func readableDataDescriptors(from descriptors: [VirtqDescriptor]) -> [VirtqDescriptor] {
        descriptors.dropFirst().filter { $0.isDeviceReadable }
    }

    private func writableDataDescriptors(from descriptors: [VirtqDescriptor]) -> [VirtqDescriptor] {
        let writable = descriptors.dropFirst().filter { $0.isDeviceWritable }
        guard writable.count > 1 else { return [] }
        return Array(writable.dropLast())
    }

    private func statusDescriptor(from descriptors: [VirtqDescriptor]) -> VirtqDescriptor? {
        descriptors.last { $0.isDeviceWritable && $0.len >= 1 }
    }

    private func writeStatus(_ status: Status, descriptors: [VirtqDescriptor], chain: DescriptorChain) {
        guard let descriptor = statusDescriptor(from: descriptors) else { return }
        chain.writeBuffer(Data([status.rawValue]), to: descriptor, maxLength: 1)
    }

    private func buildConfig() -> Data {
        var data = Data(count: 60)
        data.storeLEUInt64(backend.capacityBytes / vortexBlockSectorSize, at: 0)
        data.storeLEUInt32(1 * 1024 * 1024, at: 8) // size_max
        data.storeLEUInt32(126, at: 12)            // seg_max
        data.storeLEUInt16(1024, at: 16)           // cylinders
        data[18] = 16                              // heads
        data[19] = 63                              // sectors
        data.storeLEUInt32(blockSize, at: 20)
        data[36] = backend.isReadOnly ? 0 : 1      // writeback
        return data
    }
}

private extension Data {
    func loadLEUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    func loadLEUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
    }

    mutating func storeLEUInt16(_ value: UInt16, at offset: Int) {
        guard offset + 2 <= count else { return }
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            replaceSubrange(offset..<offset + 2, with: bytes)
        }
    }

    mutating func storeLEUInt32(_ value: UInt32, at offset: Int) {
        guard offset + 4 <= count else { return }
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            replaceSubrange(offset..<offset + 4, with: bytes)
        }
    }

    mutating func storeLEUInt64(_ value: UInt64, at offset: Int) {
        guard offset + 8 <= count else { return }
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            replaceSubrange(offset..<offset + 8, with: bytes)
        }
    }
}
