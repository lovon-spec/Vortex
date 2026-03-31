// VirtQueue.swift — Virtio 1.2 split virtqueue implementation.
// VortexDevices
//
// Implements the OASIS Virtio v1.2 specification Section 2.7 (Split Virtqueues).
// A split virtqueue consists of three memory regions in guest physical memory:
//   - Descriptor Table: array of VirtqDesc entries describing buffers
//   - Available Ring: guest-written ring of descriptor chain heads for the device
//   - Used Ring: device-written ring of completed descriptor chain heads
//
// All guest memory accesses go through GuestMemoryAccessor for safety. This avoids
// exposing raw host pointers and allows the memory access layer to be mocked for
// testing or backed by Hypervisor.framework's MemoryManager in production.
//
// Threading model: VirtQueue is NOT thread-safe by itself. The caller (typically
// VirtioDeviceBase or a device-specific handler) must serialize access.
// The audio callback path must NOT call into VirtQueue directly — use a lock-free
// ring buffer as an intermediary.

import Foundation

// MARK: - Guest Memory Accessor Protocol

/// Abstraction for reading and writing guest physical memory.
///
/// In production, this is backed by `MemoryManager.hostPointer(for:)` which
/// resolves guest physical addresses to host pointers via Hypervisor.framework
/// mappings. For testing, a simple `Data`-backed implementation suffices.
///
/// All methods are synchronous and must not block. The caller is responsible
/// for ensuring the guest physical addresses are valid and mapped.
public protocol GuestMemoryAccessor: AnyObject, Sendable {
    /// Read `size` bytes from guest physical address `gpa`.
    ///
    /// - Parameters:
    ///   - gpa: Guest physical address to read from.
    ///   - size: Number of bytes to read.
    /// - Returns: The data read, or empty data if the address is unmapped.
    func read(at gpa: UInt64, size: Int) -> Data

    /// Write `data` to guest physical address `gpa`.
    ///
    /// - Parameters:
    ///   - gpa: Guest physical address to write to.
    ///   - data: The bytes to write.
    func write(at gpa: UInt64, data: Data)
}

// MARK: - Convenience extensions for typed reads/writes

extension GuestMemoryAccessor {
    /// Read a little-endian UInt16 from guest memory.
    public func readUInt16(at gpa: UInt64) -> UInt16 {
        let data = read(at: gpa, size: 2)
        guard data.count >= 2 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    /// Read a little-endian UInt32 from guest memory.
    public func readUInt32(at gpa: UInt64) -> UInt32 {
        let data = read(at: gpa, size: 4)
        guard data.count >= 4 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    /// Read a little-endian UInt64 from guest memory.
    public func readUInt64(at gpa: UInt64) -> UInt64 {
        let data = read(at: gpa, size: 8)
        guard data.count >= 8 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }

    /// Write a little-endian UInt16 to guest memory.
    public func writeUInt16(at gpa: UInt64, value: UInt16) {
        var le = value.littleEndian
        let data = Data(bytes: &le, count: 2)
        write(at: gpa, data: data)
    }

    /// Write a little-endian UInt32 to guest memory.
    public func writeUInt32(at gpa: UInt64, value: UInt32) {
        var le = value.littleEndian
        let data = Data(bytes: &le, count: 4)
        write(at: gpa, data: data)
    }

    /// Write a little-endian UInt64 to guest memory.
    public func writeUInt64(at gpa: UInt64, value: UInt64) {
        var le = value.littleEndian
        let data = Data(bytes: &le, count: 8)
        write(at: gpa, data: data)
    }
}

// MARK: - Virtio Descriptor Flags

/// Flags for virtqueue descriptor entries (Virtio 1.2, Section 2.7.5).
public struct VirtqDescFlags: OptionSet, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The buffer continues via the `next` field.
    public static let next     = VirtqDescFlags(rawValue: 1 << 0)
    /// The buffer is device-writable (host writes, guest reads).
    /// If not set, the buffer is device-readable (guest writes, host reads).
    public static let write    = VirtqDescFlags(rawValue: 1 << 1)
    /// The buffer contains a list of indirect descriptors.
    public static let indirect = VirtqDescFlags(rawValue: 1 << 2)

    public var description: String {
        var parts: [String] = []
        if contains(.next) { parts.append("NEXT") }
        if contains(.write) { parts.append("WRITE") }
        if contains(.indirect) { parts.append("INDIRECT") }
        return parts.isEmpty ? "0" : parts.joined(separator: "|")
    }
}

// MARK: - Virtqueue Descriptor

/// A single descriptor entry in the virtqueue descriptor table.
///
/// Virtio 1.2 Section 2.7.5:
/// ```c
/// struct virtq_desc {
///     le64 addr;   // Guest physical address of the buffer
///     le32 len;    // Length of the buffer in bytes
///     le16 flags;  // VIRTQ_DESC_F_NEXT, VIRTQ_DESC_F_WRITE, VIRTQ_DESC_F_INDIRECT
///     le16 next;   // Next descriptor index if NEXT flag is set
/// };
/// ```
public struct VirtqDescriptor: Sendable {
    /// Guest physical address of the buffer.
    public let addr: UInt64
    /// Length of the buffer in bytes.
    public let len: UInt32
    /// Descriptor flags.
    public let flags: VirtqDescFlags
    /// Index of the next descriptor in the chain (valid only if `.next` flag is set).
    public let next: UInt16

    /// Size of one descriptor entry in bytes (16 bytes).
    public static let size: Int = 16

    /// Whether this descriptor's buffer is device-writable (host→guest direction).
    public var isDeviceWritable: Bool { flags.contains(.write) }

    /// Whether this descriptor's buffer is device-readable (guest→host direction).
    public var isDeviceReadable: Bool { !flags.contains(.write) }

    /// Whether this descriptor chains to another via the `next` field.
    public var hasNext: Bool { flags.contains(.next) }

    /// Whether this descriptor points to an indirect descriptor table.
    public var isIndirect: Bool { flags.contains(.indirect) }
}

// MARK: - Descriptor Chain

/// An iterator over a chain of linked virtqueue descriptors.
///
/// A descriptor chain represents a single I/O request from the guest. The chain
/// typically starts with device-readable descriptors (containing the request header
/// and data to write) followed by device-writable descriptors (for response data
/// the device fills in).
///
/// Usage:
/// ```swift
/// if let chain = queue.nextAvailableChain() {
///     for descriptor in chain {
///         if descriptor.isDeviceReadable {
///             // Read guest data from descriptor.addr, length descriptor.len
///         } else {
///             // Write response data to descriptor.addr, length descriptor.len
///         }
///     }
///     queue.addUsed(headIndex: chain.headIndex, length: bytesWritten)
/// }
/// ```
public final class DescriptorChain: Sequence, Sendable {
    /// The head descriptor index in the descriptor table (used for addUsed).
    public let headIndex: UInt16

    private let queue: VirtQueue

    /// Total number of descriptors traversed (for loop detection).
    private let maxDescriptors: UInt16

    init(headIndex: UInt16, queue: VirtQueue) {
        self.headIndex = headIndex
        self.queue = queue
        self.maxDescriptors = queue.queueSize
    }

    /// Collect all device-readable (guest→host) descriptors in the chain.
    public var readableDescriptors: [VirtqDescriptor] {
        var result: [VirtqDescriptor] = []
        for desc in self where desc.isDeviceReadable {
            result.append(desc)
        }
        return result
    }

    /// Collect all device-writable (host→guest) descriptors in the chain.
    public var writableDescriptors: [VirtqDescriptor] {
        var result: [VirtqDescriptor] = []
        for desc in self where desc.isDeviceWritable {
            result.append(desc)
        }
        return result
    }

    // MARK: - Sequence Conformance

    public struct Iterator: IteratorProtocol, Sendable {
        private let queue: VirtQueue
        private var currentIndex: UInt16?
        private var count: UInt16 = 0
        private let maxDescriptors: UInt16

        init(startIndex: UInt16, queue: VirtQueue, maxDescriptors: UInt16) {
            self.currentIndex = startIndex
            self.queue = queue
            self.maxDescriptors = maxDescriptors
        }

        public mutating func next() -> VirtqDescriptor? {
            guard let index = currentIndex else { return nil }

            // Loop detection: if we've visited more descriptors than the queue
            // can hold, the chain is malformed.
            guard count < maxDescriptors else {
                currentIndex = nil
                return nil
            }

            let descriptor = queue.readDescriptor(at: index)
            count += 1

            if descriptor.hasNext {
                let nextIndex = descriptor.next
                // Validate the next index is within bounds.
                if nextIndex < maxDescriptors {
                    currentIndex = nextIndex
                } else {
                    currentIndex = nil
                }
            } else {
                currentIndex = nil
            }

            return descriptor
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(startIndex: headIndex, queue: queue, maxDescriptors: maxDescriptors)
    }
}

// MARK: - Available Ring Flags

/// Flags in the available ring (Virtio 1.2, Section 2.7.7).
public struct VirtqAvailFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// If set, the device should not send interrupts when consuming available descriptors.
    public static let noInterrupt = VirtqAvailFlags(rawValue: 1 << 0)
}

// MARK: - Used Ring Flags

/// Flags in the used ring (Virtio 1.2, Section 2.7.8).
public struct VirtqUsedFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// If set, the guest should not notify the device when adding available descriptors.
    public static let noNotify = VirtqUsedFlags(rawValue: 1 << 0)
}

// MARK: - VirtQueue

/// A Virtio 1.2 split virtqueue implementation.
///
/// The split virtqueue uses three guest memory regions:
/// - **Descriptor Table**: Fixed-size array of `VirtqDesc` entries
/// - **Available Ring**: Written by the guest (driver), read by the device
/// - **Used Ring**: Written by the device, read by the guest (driver)
///
/// ## Memory Layout (Virtio 1.2, Section 2.7)
///
/// Descriptor Table:
/// ```
/// struct virtq_desc[queue_size]   // 16 bytes each
/// ```
///
/// Available Ring:
/// ```
/// le16 flags;                     // VirtqAvailFlags
/// le16 idx;                       // Next index the driver will write to (wraps)
/// le16 ring[queue_size];          // Descriptor chain head indices
/// le16 used_event;                // (if VIRTIO_F_EVENT_IDX) used event suppression
/// ```
///
/// Used Ring:
/// ```
/// le16 flags;                     // VirtqUsedFlags
/// le16 idx;                       // Next index the device will write to (wraps)
/// struct virtq_used_elem {        // 8 bytes each
///     le32 id;                    // Descriptor chain head index
///     le32 len;                   // Total bytes written by device
/// } ring[queue_size];
/// le16 avail_event;               // (if VIRTIO_F_EVENT_IDX) avail event suppression
/// ```
///
/// Thread safety: Not thread-safe. The caller must serialize all access.
public final class VirtQueue: @unchecked Sendable {

    // MARK: - Properties

    /// The queue index (0-based) within the device.
    public let index: UInt16

    /// The maximum number of descriptors in this queue (must be a power of 2).
    public let queueSize: UInt16

    /// Guest memory accessor for reading/writing queue structures.
    public let guestMemory: any GuestMemoryAccessor

    /// Guest physical address of the descriptor table.
    public private(set) var descriptorTableAddress: UInt64 = 0

    /// Guest physical address of the available ring.
    public private(set) var availRingAddress: UInt64 = 0

    /// Guest physical address of the used ring.
    public private(set) var usedRingAddress: UInt64 = 0

    /// Whether this queue has been fully configured and enabled by the guest.
    public private(set) var isEnabled: Bool = false

    /// The MSI-X vector assigned to this queue, or `0xFFFF` for no MSI-X.
    public var msixVector: UInt16 = 0xFFFF

    /// Device-side shadow of the last seen available ring index.
    /// Compared against the available ring's `idx` field to detect new entries.
    private var lastAvailIdx: UInt16 = 0

    /// Device-side shadow of the next used ring index to write.
    private var nextUsedIdx: UInt16 = 0

    /// Whether VIRTIO_F_EVENT_IDX has been negotiated.
    public var eventIdxEnabled: Bool = false

    // MARK: - Initialization

    /// Create a new virtqueue.
    ///
    /// - Parameters:
    ///   - index: The queue index within the device (0, 1, 2, ...).
    ///   - size: Maximum queue depth. Must be a power of 2 and at most 32768.
    ///   - guestMemory: Accessor for reading/writing guest physical memory.
    public init(index: UInt16, size: UInt16, guestMemory: any GuestMemoryAccessor) {
        precondition(size > 0 && size <= 32768, "Queue size must be 1..32768")
        precondition(size & (size - 1) == 0, "Queue size must be a power of 2")
        self.index = index
        self.queueSize = size
        self.guestMemory = guestMemory
    }

    // MARK: - Queue Setup (called during device configuration)

    /// Set the guest physical address of the descriptor table.
    public func setDescriptorTable(address: UInt64) {
        descriptorTableAddress = address
    }

    /// Set the guest physical address of the available ring.
    public func setAvailRing(address: UInt64) {
        availRingAddress = address
    }

    /// Set the guest physical address of the used ring.
    public func setUsedRing(address: UInt64) {
        usedRingAddress = address
    }

    /// Enable the queue. Called after all addresses have been configured.
    ///
    /// The queue is considered ready for I/O after this call. The device should
    /// verify that all three addresses are non-zero before enabling.
    public func enable() {
        guard descriptorTableAddress != 0,
              availRingAddress != 0,
              usedRingAddress != 0 else {
            return
        }
        isEnabled = true
    }

    /// Disable and reset the queue to its initial state.
    public func reset() {
        isEnabled = false
        descriptorTableAddress = 0
        availRingAddress = 0
        usedRingAddress = 0
        lastAvailIdx = 0
        nextUsedIdx = 0
        msixVector = 0xFFFF
        eventIdxEnabled = false
    }

    // MARK: - Descriptor Access

    /// Read a descriptor from the descriptor table at the given index.
    ///
    /// - Parameter index: Index into the descriptor table (0..<queueSize).
    /// - Returns: The descriptor at that index.
    func readDescriptor(at index: UInt16) -> VirtqDescriptor {
        let offset = UInt64(index) * UInt64(VirtqDescriptor.size)
        let gpa = descriptorTableAddress + offset
        let data = guestMemory.read(at: gpa, size: VirtqDescriptor.size)

        guard data.count >= VirtqDescriptor.size else {
            // Return a zeroed descriptor on read failure.
            return VirtqDescriptor(addr: 0, len: 0, flags: VirtqDescFlags(rawValue: 0), next: 0)
        }

        return data.withUnsafeBytes { buf in
            let addr = buf.loadUnaligned(fromByteOffset: 0, as: UInt64.self).littleEndian
            let len = buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
            let flags = buf.loadUnaligned(fromByteOffset: 12, as: UInt16.self).littleEndian
            let next = buf.loadUnaligned(fromByteOffset: 14, as: UInt16.self).littleEndian
            return VirtqDescriptor(addr: addr, len: len, flags: VirtqDescFlags(rawValue: flags), next: next)
        }
    }

    // MARK: - Available Ring Access

    /// Check whether the guest has posted new descriptor chains in the available ring.
    ///
    /// Compares the device's shadow index against the available ring's `idx` field.
    /// Returns `true` if there are unprocessed entries.
    public func hasAvailable() -> Bool {
        guard isEnabled else { return false }
        let availIdx = readAvailIdx()
        return availIdx != lastAvailIdx
    }

    /// Dequeue the next available descriptor chain from the available ring.
    ///
    /// Returns `nil` if no new chains are available. The returned `DescriptorChain`
    /// can be iterated to access each descriptor in the chain.
    ///
    /// After processing, call `addUsed(headIndex:length:)` with the chain's
    /// `headIndex` and the total bytes written by the device.
    public func nextAvailableChain() -> DescriptorChain? {
        guard isEnabled else { return nil }

        let availIdx = readAvailIdx()
        guard availIdx != lastAvailIdx else { return nil }

        // Read the ring entry. The ring index wraps modulo queueSize.
        let ringSlot = lastAvailIdx % queueSize
        let entryGPA = availRingAddress
            + 4                                       // skip flags (2) + idx (2)
            + UInt64(ringSlot) * 2                    // le16 ring entries

        let headIndex = guestMemory.readUInt16(at: entryGPA)

        // Validate the head index.
        guard headIndex < queueSize else { return nil }

        // Advance our shadow index.
        lastAvailIdx &+= 1

        return DescriptorChain(headIndex: headIndex, queue: self)
    }

    // MARK: - Used Ring Access

    /// Post a completed descriptor chain to the used ring.
    ///
    /// - Parameters:
    ///   - headIndex: The descriptor chain head index (from `DescriptorChain.headIndex`).
    ///   - length: Total number of bytes written by the device into device-writable
    ///     buffers. For device-readable-only chains, pass 0.
    public func addUsed(headIndex: UInt16, length: UInt32) {
        guard isEnabled else { return }

        // Write the used element: struct virtq_used_elem { le32 id; le32 len; }
        let ringSlot = nextUsedIdx % queueSize
        let elemGPA = usedRingAddress
            + 4                                       // skip flags (2) + idx (2)
            + UInt64(ringSlot) * 8                    // 8 bytes per used element

        guestMemory.writeUInt32(at: elemGPA, value: UInt32(headIndex))
        guestMemory.writeUInt32(at: elemGPA + 4, value: length)

        // Increment and write the used ring idx.
        nextUsedIdx &+= 1

        // Memory barrier semantics: the idx update must be visible after the element write.
        // In practice, GuestMemoryAccessor writes go through host memory that is coherent
        // with the guest, but we write idx last to maintain ordering.
        writeUsedIdx(nextUsedIdx)
    }

    /// Check whether the device should send an interrupt notification to the guest.
    ///
    /// This checks the available ring's `flags` field for `AVAIL_NO_INTERRUPT`.
    /// When `VIRTIO_F_EVENT_IDX` is negotiated, it instead checks the `used_event`
    /// field for event suppression.
    ///
    /// - Returns: `true` if the guest expects to be notified.
    public func needsNotification() -> Bool {
        guard isEnabled else { return false }

        if eventIdxEnabled {
            // VIRTIO_F_EVENT_IDX path: notify only if used_idx has reached
            // the value the guest placed in used_event.
            let usedEvent = readUsedEvent()
            // Virtio spec uses wrapping arithmetic:
            // Notify if (new_used_idx - 1 - used_event) wrapping < (new_used_idx - old_used_idx)
            // Simplified: notify if we've crossed the event threshold.
            let newIdx = nextUsedIdx
            return ringWrappingDifference(newIdx, usedEvent &+ 1) < ringWrappingDifference(newIdx, nextUsedIdx &- 1)
                || nextUsedIdx == usedEvent &+ 1
        } else {
            // Standard path: check AVAIL_NO_INTERRUPT flag.
            let flags = readAvailFlags()
            return !flags.contains(.noInterrupt)
        }
    }

    // MARK: - Event Index Suppression

    /// Write the `avail_event` field in the used ring (for VIRTIO_F_EVENT_IDX).
    ///
    /// The device writes this to tell the guest "don't notify me until your
    /// available index reaches this value."
    ///
    /// - Parameter value: The available ring index threshold.
    public func setAvailEvent(_ value: UInt16) {
        guard isEnabled, eventIdxEnabled else { return }
        // avail_event is at: used_ring + 4 + queue_size * 8
        let gpa = usedRingAddress + 4 + UInt64(queueSize) * 8
        guestMemory.writeUInt16(at: gpa, value: value)
    }

    // MARK: - Private Helpers

    /// Read the available ring's `flags` field.
    private func readAvailFlags() -> VirtqAvailFlags {
        let raw = guestMemory.readUInt16(at: availRingAddress)
        return VirtqAvailFlags(rawValue: raw)
    }

    /// Read the available ring's `idx` field (offset 2 in the avail ring).
    private func readAvailIdx() -> UInt16 {
        guestMemory.readUInt16(at: availRingAddress + 2)
    }

    /// Read the `used_event` field from the available ring.
    /// Located at: avail_ring + 4 + queue_size * 2
    private func readUsedEvent() -> UInt16 {
        let gpa = availRingAddress + 4 + UInt64(queueSize) * 2
        return guestMemory.readUInt16(at: gpa)
    }

    /// Write the used ring's `idx` field (offset 2 in the used ring).
    private func writeUsedIdx(_ value: UInt16) {
        guestMemory.writeUInt16(at: usedRingAddress + 2, value: value)
    }

    /// Write the used ring's `flags` field.
    public func setUsedFlags(_ flags: VirtqUsedFlags) {
        guestMemory.writeUInt16(at: usedRingAddress, value: flags.rawValue)
    }

    /// Unsigned wrapping difference for ring index comparison.
    private func ringWrappingDifference(_ a: UInt16, _ b: UInt16) -> UInt16 {
        a &- b
    }
}

// MARK: - VirtQueue Size Calculations

extension VirtQueue {
    /// Calculate the total byte size of the descriptor table.
    public static func descriptorTableSize(queueSize: UInt16) -> Int {
        Int(queueSize) * VirtqDescriptor.size
    }

    /// Calculate the total byte size of the available ring (including used_event).
    public static func availRingSize(queueSize: UInt16) -> Int {
        // flags (2) + idx (2) + ring[queue_size] (2 each) + used_event (2)
        2 + 2 + Int(queueSize) * 2 + 2
    }

    /// Calculate the total byte size of the used ring (including avail_event).
    public static func usedRingSize(queueSize: UInt16) -> Int {
        // flags (2) + idx (2) + ring[queue_size] * {id(4) + len(4)} + avail_event (2)
        2 + 2 + Int(queueSize) * 8 + 2
    }
}
