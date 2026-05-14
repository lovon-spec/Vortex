// VirtioGPU.swift -- VirtIO GPU 2D device emulation.
// VortexDevices

import Foundation
import VortexCore

public struct VirtioFramebuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Pixel data in the guest resource's native 32-bit layout.
    public let data: Data

    public init(width: Int, height: Int, data: Data) {
        self.width = width
        self.height = height
        self.data = data
    }
}

private enum VirtioGPUQueue {
    static let control = 0
    static let cursor = 1
    static let count = 2
}

private enum VirtioGPUConfigOffset {
    static let eventsRead = 0
    static let eventsClear = 4
    static let numScanouts = 8
    static let reserved = 12
    static let size = 16
}

private enum VirtioGPUCommand {
    static let getDisplayInfo: UInt32 = 0x0100
    static let resourceCreate2D: UInt32 = 0x0101
    static let resourceUnref: UInt32 = 0x0102
    static let setScanout: UInt32 = 0x0103
    static let resourceFlush: UInt32 = 0x0104
    static let transferToHost2D: UInt32 = 0x0105
    static let resourceAttachBacking: UInt32 = 0x0106
    static let resourceDetachBacking: UInt32 = 0x0107

    static let updateCursor: UInt32 = 0x0300
    static let moveCursor: UInt32 = 0x0301
}

private enum VirtioGPUResponse {
    static let okNoData: UInt32 = 0x1100
    static let okDisplayInfo: UInt32 = 0x1101
    static let errUnspec: UInt32 = 0x1200
    static let errInvalidParameter: UInt32 = 0x1203
}

private struct VirtioGPURect {
    var x: UInt32
    var y: UInt32
    var width: UInt32
    var height: UInt32
}

private struct VirtioGPUMemEntry {
    var address: UInt64
    var length: UInt32
}

private final class VirtioGPUResource {
    let resourceID: UInt32
    let format: UInt32
    let width: UInt32
    let height: UInt32
    var backing: [VirtioGPUMemEntry] = []
    var data: Data

    init(resourceID: UInt32, format: UInt32, width: UInt32, height: UInt32) {
        self.resourceID = resourceID
        self.format = format
        self.width = width
        self.height = height
        self.data = Data(count: Int(width) * Int(height) * 4)
    }
}

public final class VirtioGPUDevice: VirtioDeviceBase, @unchecked Sendable {
    public let displayWidth: UInt32
    public let displayHeight: UInt32
    public var onFramebufferUpdated: (@Sendable (VirtioFramebuffer) -> Void)?

    private let lock = NSLock()
    private var resources: [UInt32: VirtioGPUResource] = [:]
    private var scanoutResourceID: UInt32?

    public init(width: UInt32 = 1280, height: UInt32 = 800) {
        self.displayWidth = width
        self.displayHeight = height
        super.init(
            deviceType: .gpu,
            numQueues: VirtioGPUQueue.count,
            deviceFeatures: 0,
            configSize: VirtioGPUConfigOffset.size,
            defaultQueueSize: 256
        )
    }

    public override func readDeviceConfig(offset: Int, size: Int) -> UInt32 {
        switch offset {
        case VirtioGPUConfigOffset.eventsRead:
            return 0
        case VirtioGPUConfigOffset.eventsClear:
            return 0
        case VirtioGPUConfigOffset.numScanouts:
            return 1
        case VirtioGPUConfigOffset.reserved:
            return 0
        default:
            return 0
        }
    }

    public override func writeDeviceConfig(offset: Int, size: Int, value: UInt32) {
        // The only writable config field is events_clear. No events are exposed yet.
    }

    public override func handleQueueNotification(queueIndex: Int) {
        switch queueIndex {
        case VirtioGPUQueue.control:
            processControlQueue()
        case VirtioGPUQueue.cursor:
            processCursorQueue()
        default:
            break
        }
    }

    public override func deviceReset() {
        lock.lock()
        resources.removeAll()
        scanoutResourceID = nil
        lock.unlock()
    }

    private func processControlQueue() {
        let queue = queues[VirtioGPUQueue.control]
        while let chain = queue.nextAvailableChain() {
            let request = readRequest(from: chain)
            let response = handleControlRequest(request, memory: queue.guestMemory)
            writeResponse(response, to: chain, queue: queue)
        }
    }

    private func processCursorQueue() {
        let queue = queues[VirtioGPUQueue.cursor]
        while let chain = queue.nextAvailableChain() {
            let request = readRequest(from: chain)
            writeResponse(makeHeader(type: VirtioGPUResponse.okNoData, request: request), to: chain, queue: queue)
        }
    }

    private func handleControlRequest(_ request: Data, memory: any GuestMemoryAccessor) -> Data {
        guard request.count >= 24 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter)
        }

        let command = request.leUInt32(at: 0)
        switch command {
        case VirtioGPUCommand.getDisplayInfo:
            return displayInfoResponse(request)

        case VirtioGPUCommand.resourceCreate2D:
            return handleResourceCreate2D(request)

        case VirtioGPUCommand.resourceUnref:
            return handleResourceUnref(request)

        case VirtioGPUCommand.setScanout:
            return handleSetScanout(request)

        case VirtioGPUCommand.resourceFlush:
            return handleResourceFlush(request)

        case VirtioGPUCommand.transferToHost2D:
            return handleTransferToHost2D(request, memory: memory)

        case VirtioGPUCommand.resourceAttachBacking:
            return handleResourceAttachBacking(request)

        case VirtioGPUCommand.resourceDetachBacking:
            return handleResourceDetachBacking(request)

        default:
            return makeHeader(type: VirtioGPUResponse.errUnspec, request: request)
        }
    }

    private func handleResourceCreate2D(_ request: Data) -> Data {
        guard request.count >= 40 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let resourceID = request.leUInt32(at: 24)
        let format = request.leUInt32(at: 28)
        let width = request.leUInt32(at: 32)
        let height = request.leUInt32(at: 36)
        guard resourceID != 0, width > 0, height > 0 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }

        lock.lock()
        resources[resourceID] = VirtioGPUResource(
            resourceID: resourceID,
            format: format,
            width: width,
            height: height
        )
        lock.unlock()
        return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
    }

    private func handleResourceUnref(_ request: Data) -> Data {
        guard request.count >= 32 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let resourceID = request.leUInt32(at: 24)
        lock.lock()
        resources.removeValue(forKey: resourceID)
        if scanoutResourceID == resourceID {
            scanoutResourceID = nil
        }
        lock.unlock()
        return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
    }

    private func handleSetScanout(_ request: Data) -> Data {
        guard request.count >= 48 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let scanoutID = request.leUInt32(at: 40)
        let resourceID = request.leUInt32(at: 44)
        guard scanoutID == 0 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }

        lock.lock()
        if resourceID == 0 {
            scanoutResourceID = nil
            lock.unlock()
            return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
        }
        guard resources[resourceID] != nil else {
            lock.unlock()
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        scanoutResourceID = resourceID
        lock.unlock()
        publishFramebuffer(resourceID: resourceID)
        return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
    }

    private func handleResourceFlush(_ request: Data) -> Data {
        guard request.count >= 48 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let resourceID = request.leUInt32(at: 40)
        publishFramebuffer(resourceID: resourceID)
        return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
    }

    private func handleTransferToHost2D(_ request: Data, memory: any GuestMemoryAccessor) -> Data {
        guard request.count >= 56 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let rect = VirtioGPURect(
            x: request.leUInt32(at: 24),
            y: request.leUInt32(at: 28),
            width: request.leUInt32(at: 32),
            height: request.leUInt32(at: 36)
        )
        let offset = request.leUInt64(at: 40)
        let resourceID = request.leUInt32(at: 48)

        lock.lock()
        guard let resource = resources[resourceID] else {
            lock.unlock()
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let backing = resource.backing
        lock.unlock()

        let bytesPerPixel = 4
        let stride = Int(resource.width) * bytesPerPixel
        guard rect.x < resource.width, rect.y < resource.height else {
            return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
        }
        let availableWidth = Int(resource.width - rect.x)
        let availableHeight = Int(resource.height - rect.y)
        let copyWidth = min(Int(rect.width), availableWidth)
        let copyHeight = min(Int(rect.height), availableHeight)
        guard copyWidth > 0, copyHeight > 0 else {
            return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
        }

        lock.lock()
        for row in 0..<copyHeight {
            let sourceOffset = Int(offset) + row * stride
            let destOffset = (Int(rect.y) + row) * stride + Int(rect.x) * bytesPerPixel
            let length = copyWidth * bytesPerPixel
            let rowData = readBacking(backing, offset: sourceOffset, length: length, memory: memory)
            if rowData.count == length, destOffset + length <= resource.data.count {
                resource.data.replaceSubrange(destOffset..<(destOffset + length), with: rowData)
            }
        }
        lock.unlock()

        return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
    }

    private func handleResourceAttachBacking(_ request: Data) -> Data {
        guard request.count >= 32 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let resourceID = request.leUInt32(at: 24)
        let entryCount = Int(request.leUInt32(at: 28))
        let expectedSize = 32 + entryCount * 16
        guard request.count >= expectedSize else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }

        var entries: [VirtioGPUMemEntry] = []
        for index in 0..<entryCount {
            let base = 32 + index * 16
            entries.append(VirtioGPUMemEntry(
                address: request.leUInt64(at: base),
                length: request.leUInt32(at: base + 8)
            ))
        }

        lock.lock()
        guard let resource = resources[resourceID] else {
            lock.unlock()
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        resource.backing = entries
        lock.unlock()
        return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
    }

    private func handleResourceDetachBacking(_ request: Data) -> Data {
        guard request.count >= 32 else {
            return makeHeader(type: VirtioGPUResponse.errInvalidParameter, request: request)
        }
        let resourceID = request.leUInt32(at: 24)
        lock.lock()
        resources[resourceID]?.backing.removeAll()
        lock.unlock()
        return makeHeader(type: VirtioGPUResponse.okNoData, request: request)
    }

    private func displayInfoResponse(_ request: Data) -> Data {
        var response = makeHeader(type: VirtioGPUResponse.okDisplayInfo, request: request)
        for index in 0..<16 {
            if index == 0 {
                response.appendLE(UInt32(0))
                response.appendLE(UInt32(0))
                response.appendLE(displayWidth)
                response.appendLE(displayHeight)
                response.appendLE(UInt32(1))
                response.appendLE(UInt32(0))
            } else {
                response.append(Data(count: 24))
            }
        }
        return response
    }

    private func publishFramebuffer(resourceID: UInt32) {
        lock.lock()
        guard scanoutResourceID == resourceID,
              let resource = resources[resourceID] else {
            lock.unlock()
            return
        }
        let framebuffer = VirtioFramebuffer(
            width: Int(resource.width),
            height: Int(resource.height),
            data: resource.data
        )
        lock.unlock()
        onFramebufferUpdated?(framebuffer)
    }

    private func readRequest(from chain: DescriptorChain) -> Data {
        var data = Data()
        for descriptor in chain where descriptor.isDeviceReadable {
            data.append(chain.readBuffer(descriptor))
        }
        return data
    }

    private func writeResponse(_ response: Data, to chain: DescriptorChain, queue: VirtQueue) {
        var remaining = response
        var written = 0
        for descriptor in chain where descriptor.isDeviceWritable {
            guard !remaining.isEmpty else { break }
            let count = min(Int(descriptor.len), remaining.count)
            chain.writeBuffer(remaining.prefixData(count), to: descriptor)
            remaining.removeFirst(count)
            written += count
        }
        queue.addUsed(headIndex: chain.headIndex, length: UInt32(written))
        signalUsedBuffers(queueIndex: Int(queue.index))
    }

    private func readBacking(
        _ backing: [VirtioGPUMemEntry],
        offset: Int,
        length: Int,
        memory: any GuestMemoryAccessor
    ) -> Data {
        var remainingOffset = offset
        var remainingLength = length
        var result = Data()
        for entry in backing {
            let entryLength = Int(entry.length)
            if remainingOffset >= entryLength {
                remainingOffset -= entryLength
                continue
            }
            let available = min(remainingLength, entryLength - remainingOffset)
            result.append(memory.read(at: entry.address + UInt64(remainingOffset), size: available))
            remainingLength -= available
            remainingOffset = 0
            if remainingLength == 0 {
                break
            }
        }
        return result
    }

    private func makeHeader(type: UInt32, request: Data? = nil) -> Data {
        var data = Data()
        data.appendLE(type)
        if let request, request.count >= 24 {
            data.appendLE(request.leUInt32(at: 4))
            data.appendLE(request.leUInt64(at: 8))
            data.appendLE(request.leUInt32(at: 16))
            data.appendLE(request.leUInt32(at: 20))
        } else {
            data.appendLE(UInt32(0))
            data.appendLE(UInt64(0))
            data.appendLE(UInt32(0))
            data.appendLE(UInt32(0))
        }
        return data
    }
}

private extension Data {
    func leUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    func leUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    func prefixData(_ count: Int) -> Data {
        subdata(in: startIndex..<index(startIndex, offsetBy: count))
    }

    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
