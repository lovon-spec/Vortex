// VirtioInput.swift -- VirtIO input device emulation.
// VortexDevices

import Foundation
import VortexCore

public enum VirtioInputProfile: Sendable, Equatable {
    case keyboard
    case tablet(width: UInt32, height: UInt32)
}

public struct VirtioInputPointerButtons: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = VirtioInputPointerButtons(rawValue: 1 << 0)
    public static let right = VirtioInputPointerButtons(rawValue: 1 << 1)
    public static let middle = VirtioInputPointerButtons(rawValue: 1 << 2)
}

private enum VirtioInputQueue {
    static let event = 0
    static let status = 1
    static let count = 2
}

private enum VirtioInputConfigOffset {
    static let select = 0
    static let subsel = 1
    static let size = 2
    static let payload = 8
    static let payloadSize = 128
    static let totalSize = payload + payloadSize
}

private enum VirtioInputConfigSelect {
    static let unset: UInt8 = 0x00
    static let name: UInt8 = 0x01
    static let serial: UInt8 = 0x02
    static let devids: UInt8 = 0x03
    static let propBits: UInt8 = 0x10
    static let evBits: UInt8 = 0x11
    static let absInfo: UInt8 = 0x12
}

private enum LinuxInput {
    static let busVirtual: UInt16 = 0x06

    static let evSyn: UInt16 = 0x00
    static let evKey: UInt16 = 0x01
    static let evAbs: UInt16 = 0x03

    static let synReport: UInt16 = 0x00

    static let absX: UInt16 = 0x00
    static let absY: UInt16 = 0x01

    static let btnLeft: UInt16 = 0x110
    static let btnRight: UInt16 = 0x111
    static let btnMiddle: UInt16 = 0x112

    static let inputPropDirect: UInt16 = 0x01
}

private struct VirtioInputEvent: Sendable {
    let type: UInt16
    let code: UInt16
    let value: Int32

    var data: Data {
        var result = Data()
        result.appendLE(type)
        result.appendLE(code)
        result.appendLE(UInt32(bitPattern: value))
        return result
    }
}

public final class VirtioInputDevice: VirtioDeviceBase, @unchecked Sendable {
    public let profile: VirtioInputProfile

    private let lock = NSLock()
    private var configSelect: UInt8 = VirtioInputConfigSelect.unset
    private var configSubselect: UInt8 = 0
    private var pendingEvents: [VirtioInputEvent] = []
    private var pointerButtons: VirtioInputPointerButtons = []

    public init(profile: VirtioInputProfile) {
        self.profile = profile
        super.init(
            deviceType: .input,
            numQueues: VirtioInputQueue.count,
            deviceFeatures: 0,
            configSize: VirtioInputConfigOffset.totalSize,
            defaultQueueSize: 64
        )
    }

    public override func readDeviceConfig(offset: Int, size: Int) -> UInt32 {
        lock.lock()
        let bytes = configBytesLocked()
        lock.unlock()

        guard offset >= 0, size > 0, offset < bytes.count else {
            return 0
        }
        let end = min(offset + size, bytes.count)
        var value: UInt32 = 0
        for index in offset..<end {
            value |= UInt32(bytes[index]) << UInt32((index - offset) * 8)
        }
        return value
    }

    public override func writeDeviceConfig(offset: Int, size: Int, value: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case VirtioInputConfigOffset.select:
            configSelect = UInt8(value & 0xff)
        case VirtioInputConfigOffset.subsel:
            configSubselect = UInt8(value & 0xff)
        default:
            break
        }
    }

    public override func handleQueueNotification(queueIndex: Int) {
        lock.lock()
        defer { lock.unlock() }

        switch queueIndex {
        case VirtioInputQueue.event:
            drainEventQueueLocked()
        case VirtioInputQueue.status:
            processStatusQueueLocked()
        default:
            break
        }
    }

    public override func deviceReset() {
        lock.lock()
        configSelect = VirtioInputConfigSelect.unset
        configSubselect = 0
        pendingEvents.removeAll()
        pointerButtons = []
        lock.unlock()
    }

    public func sendKey(code: UInt16, pressed: Bool) {
        enqueue([
            VirtioInputEvent(type: LinuxInput.evKey, code: code, value: pressed ? 1 : 0),
            VirtioInputEvent(type: LinuxInput.evSyn, code: LinuxInput.synReport, value: 0),
        ])
    }

    public func sendTabletPointer(x: UInt32, y: UInt32, buttons: VirtioInputPointerButtons) {
        guard case let .tablet(width, height) = profile else {
            return
        }

        let clampedX = min(x, max(width, 1) - 1)
        let clampedY = min(y, max(height, 1) - 1)

        lock.lock()
        let changedButtons = pointerButtons.symmetricDifference(buttons)
        pointerButtons = buttons

        var events = [
            VirtioInputEvent(type: LinuxInput.evAbs, code: LinuxInput.absX, value: Int32(clampedX)),
            VirtioInputEvent(type: LinuxInput.evAbs, code: LinuxInput.absY, value: Int32(clampedY)),
        ]

        appendButtonEvents(
            changedButtons: changedButtons,
            buttons: buttons,
            to: &events
        )
        events.append(VirtioInputEvent(type: LinuxInput.evSyn, code: LinuxInput.synReport, value: 0))

        pendingEvents.append(contentsOf: events)
        drainEventQueueLocked()
        lock.unlock()
    }

    private func enqueue(_ events: [VirtioInputEvent]) {
        lock.lock()
        pendingEvents.append(contentsOf: events)
        drainEventQueueLocked()
        lock.unlock()
    }

    private func drainEventQueueLocked() {
        let queue = queues[VirtioInputQueue.event]
        while !pendingEvents.isEmpty, let chain = queue.nextAvailableChain() {
            let event = pendingEvents.removeFirst()
            let written = write(event.data, to: chain)
            queue.addUsed(headIndex: chain.headIndex, length: UInt32(written))
            signalUsedBuffers(queueIndex: VirtioInputQueue.event)
        }
    }

    private func processStatusQueueLocked() {
        let queue = queues[VirtioInputQueue.status]
        while let chain = queue.nextAvailableChain() {
            queue.addUsed(headIndex: chain.headIndex, length: 0)
            signalUsedBuffers(queueIndex: VirtioInputQueue.status)
        }
    }

    private func write(_ data: Data, to chain: DescriptorChain) -> Int {
        var remaining = data
        var written = 0
        for descriptor in chain where descriptor.isDeviceWritable {
            guard !remaining.isEmpty else { break }
            let count = min(Int(descriptor.len), remaining.count)
            chain.writeBuffer(remaining.prefixData(count), to: descriptor)
            remaining.removeFirst(count)
            written += count
        }
        return written
    }

    private func appendButtonEvents(
        changedButtons: VirtioInputPointerButtons,
        buttons: VirtioInputPointerButtons,
        to events: inout [VirtioInputEvent]
    ) {
        let mappings: [(VirtioInputPointerButtons, UInt16)] = [
            (.left, LinuxInput.btnLeft),
            (.right, LinuxInput.btnRight),
            (.middle, LinuxInput.btnMiddle),
        ]

        for (button, code) in mappings where changedButtons.contains(button) {
            events.append(VirtioInputEvent(
                type: LinuxInput.evKey,
                code: code,
                value: buttons.contains(button) ? 1 : 0
            ))
        }
    }

    private func configBytesLocked() -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: VirtioInputConfigOffset.payloadSize)
        let payloadSize: UInt8

        switch configSelect {
        case VirtioInputConfigSelect.name:
            payloadSize = writeStringPayload(deviceName, into: &payload)
        case VirtioInputConfigSelect.serial:
            payloadSize = writeStringPayload(deviceSerial, into: &payload)
        case VirtioInputConfigSelect.devids:
            writeDeviceIDs(into: &payload)
            payloadSize = 8
        case VirtioInputConfigSelect.propBits:
            writePropertyBits(into: &payload)
            payloadSize = trimmedPayloadSize(payload)
        case VirtioInputConfigSelect.evBits:
            writeEventBits(subselect: UInt16(configSubselect), into: &payload)
            payloadSize = trimmedPayloadSize(payload)
        case VirtioInputConfigSelect.absInfo:
            payloadSize = writeAbsInfo(subselect: UInt16(configSubselect), into: &payload)
        default:
            payloadSize = 0
        }

        var bytes = [UInt8](repeating: 0, count: VirtioInputConfigOffset.totalSize)
        bytes[VirtioInputConfigOffset.select] = configSelect
        bytes[VirtioInputConfigOffset.subsel] = configSubselect
        bytes[VirtioInputConfigOffset.size] = payloadSize
        for index in 0..<payload.count {
            bytes[VirtioInputConfigOffset.payload + index] = payload[index]
        }
        return bytes
    }

    private var deviceName: String {
        switch profile {
        case .keyboard:
            return "Vortex VirtIO Keyboard"
        case .tablet:
            return "Vortex VirtIO Tablet"
        }
    }

    private var deviceSerial: String {
        switch profile {
        case .keyboard:
            return "vortex-keyboard"
        case .tablet:
            return "vortex-tablet"
        }
    }

    private func writeDeviceIDs(into payload: inout [UInt8]) {
        writeLE(LinuxInput.busVirtual, into: &payload, at: 0)
        writeLE(UInt16(0x1af4), into: &payload, at: 2)
        switch profile {
        case .keyboard:
            writeLE(UInt16(0x0001), into: &payload, at: 4)
        case .tablet:
            writeLE(UInt16(0x0002), into: &payload, at: 4)
        }
        writeLE(UInt16(0x0001), into: &payload, at: 6)
    }

    private func writePropertyBits(into payload: inout [UInt8]) {
        guard case .tablet = profile else {
            return
        }
        setBit(LinuxInput.inputPropDirect, in: &payload)
    }

    private func writeEventBits(subselect: UInt16, into payload: inout [UInt8]) {
        switch subselect {
        case 0:
            setBit(LinuxInput.evSyn, in: &payload)
            setBit(LinuxInput.evKey, in: &payload)
            if case .tablet = profile {
                setBit(LinuxInput.evAbs, in: &payload)
            }
        case LinuxInput.evKey:
            switch profile {
            case .keyboard:
                for code in UInt16(1)...UInt16(255) {
                    setBit(code, in: &payload)
                }
            case .tablet:
                setBit(LinuxInput.btnLeft, in: &payload)
                setBit(LinuxInput.btnRight, in: &payload)
                setBit(LinuxInput.btnMiddle, in: &payload)
            }
        case LinuxInput.evAbs:
            guard case .tablet = profile else {
                return
            }
            setBit(LinuxInput.absX, in: &payload)
            setBit(LinuxInput.absY, in: &payload)
        default:
            break
        }
    }

    private func writeAbsInfo(subselect: UInt16, into payload: inout [UInt8]) -> UInt8 {
        guard case let .tablet(width, height) = profile else {
            return 0
        }

        switch subselect {
        case LinuxInput.absX:
            writeAbsInfo(min: 0, max: max(width, 1) - 1, into: &payload)
            return 20
        case LinuxInput.absY:
            writeAbsInfo(min: 0, max: max(height, 1) - 1, into: &payload)
            return 20
        default:
            return 0
        }
    }

    private func writeAbsInfo(min: UInt32, max: UInt32, into payload: inout [UInt8]) {
        writeLE(min, into: &payload, at: 0)
        writeLE(max, into: &payload, at: 4)
        writeLE(UInt32(0), into: &payload, at: 8)
        writeLE(UInt32(0), into: &payload, at: 12)
        writeLE(UInt32(0), into: &payload, at: 16)
    }

    private func writeStringPayload(_ value: String, into payload: inout [UInt8]) -> UInt8 {
        let bytes = Array(value.utf8.prefix(VirtioInputConfigOffset.payloadSize))
        for (index, byte) in bytes.enumerated() {
            payload[index] = byte
        }
        return UInt8(bytes.count)
    }

    private func trimmedPayloadSize(_ payload: [UInt8]) -> UInt8 {
        guard let last = payload.lastIndex(where: { $0 != 0 }) else {
            return 0
        }
        return UInt8(last + 1)
    }

    private func setBit(_ bit: UInt16, in payload: inout [UInt8]) {
        let index = Int(bit / 8)
        guard index < payload.count else {
            return
        }
        payload[index] |= UInt8(1 << (bit % 8))
    }

    private func writeLE(_ value: UInt16, into payload: inout [UInt8], at offset: Int) {
        guard offset + 2 <= payload.count else { return }
        payload[offset] = UInt8(value & 0xff)
        payload[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private func writeLE(_ value: UInt32, into payload: inout [UInt8], at offset: Int) {
        guard offset + 4 <= payload.count else { return }
        payload[offset] = UInt8(value & 0xff)
        payload[offset + 1] = UInt8((value >> 8) & 0xff)
        payload[offset + 2] = UInt8((value >> 16) & 0xff)
        payload[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}

private extension Data {
    func prefixData(_ count: Int) -> Data {
        subdata(in: startIndex..<index(startIndex, offsetBy: count))
    }

    mutating func appendLE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
