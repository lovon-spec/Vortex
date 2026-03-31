// PCIInterruptMapper.swift -- MSI-X capability and table emulation for PCI devices.
// VortexHV
//
// Implements the MSI-X capability structure, table, and Pending Bit Array (PBA)
// as defined by the PCI Local Bus Specification 3.0 and PCI Express 5.0.
//
// MSI-X is the preferred interrupt mechanism for virtio-pci devices. Each virtqueue
// gets its own MSI-X vector, enabling efficient per-queue interrupt delivery without
// sharing INTx lines.

import Foundation

// MARK: - MSI-X Constants

/// MSI-X capability structure offsets (relative to capability start).
private enum MSIXCapOffset {
    /// Capability ID (0x11 for MSI-X) -- 1 byte.
    static let capID: Int = 0x00
    /// Next capability pointer -- 1 byte.
    static let nextCap: Int = 0x01
    /// Message Control register -- 2 bytes.
    static let messageControl: Int = 0x02
    /// Table offset and BAR indicator -- 4 bytes.
    static let tableOffsetBIR: Int = 0x04
    /// PBA offset and BAR indicator -- 4 bytes.
    static let pbaOffsetBIR: Int = 0x08
    /// Total size of the MSI-X capability structure.
    static let size: Int = 0x0C
}

/// MSI-X Message Control register bits.
private enum MSIXMessageControl {
    /// Table size field: bits [10:0] (N-1, where N is the number of entries).
    static let tableSizeMask: UInt16 = 0x07FF
    /// Function mask bit (bit 14) -- when set, all vectors are masked.
    static let functionMask: UInt16 = 1 << 14
    /// MSI-X enable bit (bit 15).
    static let enable: UInt16 = 1 << 15
}

// MARK: - MSI-X Table Entry

/// A single entry in the MSI-X table. Each entry maps to one interrupt vector.
///
/// Layout (16 bytes per entry):
/// - Offset 0x00: Message Address (lower 32 bits)
/// - Offset 0x04: Message Address (upper 32 bits)
/// - Offset 0x08: Message Data (32 bits)
/// - Offset 0x0C: Vector Control (bit 0 = masked)
public struct MSIXTableEntry: Sendable {
    /// The full 64-bit message address (MSI doorbell GPA).
    public var messageAddress: UInt64
    /// The 32-bit message data (typically the interrupt vector ID / INTID).
    public var messageData: UInt32
    /// Vector control: bit 0 = masked (1 = masked, 0 = unmasked).
    public var vectorControl: UInt32

    /// Whether this vector is masked.
    public var isMasked: Bool {
        (vectorControl & 0x1) != 0
    }

    public init(messageAddress: UInt64 = 0, messageData: UInt32 = 0, vectorControl: UInt32 = 0x1) {
        self.messageAddress = messageAddress
        self.messageData = messageData
        self.vectorControl = vectorControl // Masked by default per spec
    }
}

// MARK: - MSI-X Capability

/// Describes the MSI-X capability layout for a PCI device.
///
/// This is written into the PCI config space capability chain and tells the
/// guest driver where to find the MSI-X table and PBA in BAR space.
public struct MSIXCapability: Sendable {
    /// The BAR index that contains the MSI-X table.
    public let tableBAR: Int
    /// Byte offset within the BAR to the start of the MSI-X table.
    public let tableOffset: UInt32
    /// The BAR index that contains the Pending Bit Array.
    public let pbaBAR: Int
    /// Byte offset within the BAR to the start of the PBA.
    public let pbaOffset: UInt32
    /// Number of MSI-X table entries (1-2048).
    public let tableSize: Int

    public init(tableBAR: Int, tableOffset: UInt32, pbaBAR: Int, pbaOffset: UInt32, tableSize: Int) {
        precondition(tableSize >= 1 && tableSize <= 2048, "MSI-X table size must be 1-2048")
        self.tableBAR = tableBAR
        self.tableOffset = tableOffset
        self.pbaBAR = pbaBAR
        self.pbaOffset = pbaOffset
        self.tableSize = tableSize
    }

    /// The size in bytes of the MSI-X table region (16 bytes per entry).
    public var tableByteSize: Int { tableSize * 16 }

    /// The size in bytes of the PBA region (1 bit per entry, rounded up to 8 bytes).
    public var pbaByteSize: Int { ((tableSize + 63) / 64) * 8 }
}

// MARK: - MSI-X Controller

/// Manages the MSI-X table and PBA for a single PCI device.
///
/// This class handles:
/// 1. Config space reads/writes for the MSI-X capability structure.
/// 2. MMIO reads/writes for the MSI-X table and PBA in BAR space.
/// 3. Triggering MSI interrupts by writing to the GIC MSI doorbell.
///
/// **Threading**: Methods may be called from any vCPU thread. Internal state
/// is protected by a lock.
public final class MSIXController: @unchecked Sendable {
    /// The MSI-X capability descriptor.
    public let capability: MSIXCapability

    /// The MSI controller to delegate MSI writes to.
    public weak var msiController: MSIController?

    /// MSI-X table entries (one per vector).
    private var table: [MSIXTableEntry]

    /// Pending Bit Array (one bit per vector, stored as UInt64 words).
    private var pba: [UInt64]

    /// MSI-X enabled flag (from Message Control register).
    private var enabled: Bool = false

    /// Function mask flag (from Message Control register).
    private var functionMasked: Bool = false

    /// The byte offset in config space where this capability starts.
    public let configOffset: Int

    private let lock = NSLock()

    // MARK: - Initialization

    /// Create an MSI-X controller.
    ///
    /// - Parameters:
    ///   - capability: Describes the MSI-X table/PBA layout.
    ///   - configOffset: The byte offset in PCI config space where the MSI-X
    ///     capability structure is placed (typically 0x40 or later).
    ///   - msiController: The platform MSI controller for doorbell writes.
    public init(capability: MSIXCapability, configOffset: Int, msiController: MSIController?) {
        self.capability = capability
        self.configOffset = configOffset
        self.msiController = msiController

        // Initialize table with all vectors masked.
        table = [MSIXTableEntry](repeating: MSIXTableEntry(), count: capability.tableSize)

        // Initialize PBA with no bits set (no pending interrupts).
        let pbaWords = (capability.tableSize + 63) / 64
        pba = [UInt64](repeating: 0, count: pbaWords)
    }

    // MARK: - Config Space Integration

    /// Write the MSI-X capability structure into a PCI config space.
    ///
    /// Call this during device initialization to place the capability in the
    /// config space chain.
    ///
    /// - Parameters:
    ///   - configSpace: The device's config space to modify.
    ///   - nextCapPointer: The next capability pointer value (0 if this is the last cap).
    public func writeCapabilityToConfigSpace(_ configSpace: inout PCIConfigSpace, nextCapPointer: UInt8 = 0) {
        let offset = configOffset

        // Cap ID = 0x11 (MSI-X).
        configSpace.write8(at: offset + MSIXCapOffset.capID, value: 0x11)
        // Next cap pointer.
        configSpace.write8(at: offset + MSIXCapOffset.nextCap, value: nextCapPointer)
        // Message Control: table size = N-1, initially disabled and function-masked.
        let msgCtrl = UInt16(capability.tableSize - 1) & MSIXMessageControl.tableSizeMask
        configSpace.write16(at: offset + MSIXCapOffset.messageControl, value: msgCtrl)
        // Table offset + BIR.
        let tableOffsetBIR = (capability.tableOffset & 0xFFFF_FFF8) | UInt32(capability.tableBAR & 0x7)
        configSpace.write32(at: offset + MSIXCapOffset.tableOffsetBIR, value: tableOffsetBIR)
        // PBA offset + BIR.
        let pbaOffsetBIR = (capability.pbaOffset & 0xFFFF_FFF8) | UInt32(capability.pbaBAR & 0x7)
        configSpace.write32(at: offset + MSIXCapOffset.pbaOffsetBIR, value: pbaOffsetBIR)

        // Update the capabilities pointer if this is the first capability.
        if configSpace.capabilitiesPointer == 0 {
            configSpace.capabilitiesPointer = UInt8(offset)
        }
    }

    /// Handle a config space read that falls within the MSI-X capability.
    /// Returns nil if the offset is not within this capability.
    public func readConfigCapability(offset: Int, size: Int) -> UInt32? {
        let relOffset = offset - configOffset
        guard relOffset >= 0 && relOffset < MSIXCapOffset.size else { return nil }

        lock.lock()
        defer { lock.unlock() }

        switch relOffset {
        case MSIXCapOffset.capID:
            return 0x11
        case MSIXCapOffset.nextCap:
            // Read from config space directly for the next pointer.
            return nil // Let the default config space reader handle it
        case MSIXCapOffset.messageControl:
            var ctrl = UInt16(capability.tableSize - 1) & MSIXMessageControl.tableSizeMask
            if enabled { ctrl |= MSIXMessageControl.enable }
            if functionMasked { ctrl |= MSIXMessageControl.functionMask }
            return UInt32(ctrl)
        case MSIXCapOffset.tableOffsetBIR:
            let val = (capability.tableOffset & 0xFFFF_FFF8) | UInt32(capability.tableBAR & 0x7)
            return val
        case MSIXCapOffset.pbaOffsetBIR:
            let val = (capability.pbaOffset & 0xFFFF_FFF8) | UInt32(capability.pbaBAR & 0x7)
            return val
        default:
            return nil
        }
    }

    /// Handle a config space write that falls within the MSI-X capability.
    /// Returns true if the write was consumed, false if not within this capability.
    public func writeConfigCapability(offset: Int, size: Int, value: UInt32) -> Bool {
        let relOffset = offset - configOffset
        guard relOffset >= 0 && relOffset < MSIXCapOffset.size else { return false }

        lock.lock()
        defer { lock.unlock() }

        switch relOffset {
        case MSIXCapOffset.messageControl:
            let ctrl = UInt16(truncatingIfNeeded: value)
            enabled = (ctrl & MSIXMessageControl.enable) != 0
            functionMasked = (ctrl & MSIXMessageControl.functionMask) != 0

            // When function mask is cleared and MSI-X is enabled,
            // deliver any pending-but-unmasked interrupts.
            if enabled && !functionMasked {
                deliverPendingInterrupts()
            }
            return true

        case MSIXCapOffset.capID, MSIXCapOffset.nextCap,
             MSIXCapOffset.tableOffsetBIR, MSIXCapOffset.pbaOffsetBIR:
            // Read-only fields -- ignore writes.
            return true

        default:
            return false
        }
    }

    // MARK: - MSI-X Table MMIO

    /// Read from the MSI-X table region.
    ///
    /// - Parameters:
    ///   - offset: Byte offset from the start of the MSI-X table.
    ///   - size: Access width in bytes.
    /// - Returns: The read value.
    public func readTable(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        let entryIndex = Int(offset / 16)
        let entryOffset = Int(offset % 16)
        guard entryIndex < table.count else { return 0 }

        let entry = table[entryIndex]
        switch entryOffset {
        case 0x00: // Message Address Low
            return UInt64(UInt32(truncatingIfNeeded: entry.messageAddress))
        case 0x04: // Message Address High
            return UInt64(UInt32(truncatingIfNeeded: entry.messageAddress >> 32))
        case 0x08: // Message Data
            return UInt64(entry.messageData)
        case 0x0C: // Vector Control
            return UInt64(entry.vectorControl)
        default:
            return 0
        }
    }

    /// Write to the MSI-X table region.
    ///
    /// - Parameters:
    ///   - offset: Byte offset from the start of the MSI-X table.
    ///   - size: Access width in bytes.
    ///   - value: The value to write.
    public func writeTable(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()

        let entryIndex = Int(offset / 16)
        let entryOffset = Int(offset % 16)
        guard entryIndex < table.count else {
            lock.unlock()
            return
        }

        let wasMasked = table[entryIndex].isMasked

        switch entryOffset {
        case 0x00: // Message Address Low
            let low = UInt32(truncatingIfNeeded: value)
            let high = UInt32(truncatingIfNeeded: table[entryIndex].messageAddress >> 32)
            table[entryIndex].messageAddress = UInt64(high) << 32 | UInt64(low)
        case 0x04: // Message Address High
            let low = UInt32(truncatingIfNeeded: table[entryIndex].messageAddress)
            let high = UInt32(truncatingIfNeeded: value)
            table[entryIndex].messageAddress = UInt64(high) << 32 | UInt64(low)
        case 0x08: // Message Data
            table[entryIndex].messageData = UInt32(truncatingIfNeeded: value)
        case 0x0C: // Vector Control
            table[entryIndex].vectorControl = UInt32(truncatingIfNeeded: value)
        default:
            lock.unlock()
            return
        }

        let isNowUnmasked = !table[entryIndex].isMasked

        // If the vector was just unmasked, check if there is a pending interrupt.
        if wasMasked && isNowUnmasked && enabled && !functionMasked {
            let wordIndex = entryIndex / 64
            let bitIndex = entryIndex % 64
            if wordIndex < pba.count && (pba[wordIndex] & (1 << bitIndex)) != 0 {
                // Clear the PBA bit and fire the interrupt.
                pba[wordIndex] &= ~(UInt64(1) << bitIndex)
                let entry = table[entryIndex]
                lock.unlock()
                fireInterrupt(entry: entry)
                return
            }
        }

        lock.unlock()
    }

    // MARK: - PBA MMIO

    /// Read from the Pending Bit Array region.
    ///
    /// - Parameters:
    ///   - offset: Byte offset from the start of the PBA.
    ///   - size: Access width in bytes.
    /// - Returns: The read value.
    public func readPBA(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        // PBA is an array of 64-bit words.
        let wordIndex = Int(offset / 8)
        guard wordIndex < pba.count else { return 0 }

        let byteOffset = Int(offset % 8)
        let word = pba[wordIndex]

        switch size {
        case 4:
            if byteOffset == 0 {
                return UInt64(UInt32(truncatingIfNeeded: word))
            } else {
                return UInt64(UInt32(truncatingIfNeeded: word >> 32))
            }
        case 8:
            return word
        default:
            let shift = byteOffset * 8
            return (word >> shift) & ((1 << (size * 8)) - 1)
        }
    }

    /// Write to the PBA region. Per the PCI spec, software writes to the PBA
    /// produce undefined results, so we ignore them.
    public func writePBA(offset: UInt64, size: Int, value: UInt64) {
        // PBA is read-only per PCI spec. Ignore writes.
    }

    // MARK: - Interrupt Triggering

    /// Signal an MSI-X interrupt for the given vector.
    ///
    /// If the vector is masked (per-vector or function mask), the interrupt is
    /// recorded in the PBA and will be delivered when the mask is cleared.
    ///
    /// - Parameter vector: The MSI-X vector index (0-based).
    public func triggerInterrupt(vector: Int) {
        lock.lock()

        guard vector < table.count else {
            lock.unlock()
            return
        }

        guard enabled else {
            lock.unlock()
            return
        }

        let entry = table[vector]

        if functionMasked || entry.isMasked {
            // Set the pending bit -- will be delivered when unmasked.
            let wordIndex = vector / 64
            let bitIndex = vector % 64
            if wordIndex < pba.count {
                pba[wordIndex] |= (UInt64(1) << bitIndex)
            }
            lock.unlock()
            return
        }

        lock.unlock()
        fireInterrupt(entry: entry)
    }

    /// Check whether MSI-X is currently enabled by the guest.
    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Get the number of MSI-X vectors.
    public var vectorCount: Int {
        capability.tableSize
    }

    // MARK: - Private

    /// Actually fire the interrupt by writing to the MSI doorbell address.
    private func fireInterrupt(entry: MSIXTableEntry) {
        guard entry.messageAddress != 0 else { return }

        // The guest programs the MSI-X table with the MSI controller's doorbell
        // address and the INTID as data. We write to the MSI controller's MMIO
        // region to trigger the SPI.
        msiController?.mmioWrite(
            offset: 0, // SETSPI_NSR at offset 0
            size: 4,
            value: UInt64(entry.messageData)
        )
    }

    /// Deliver any pending-but-unmasked interrupts (called after mask changes).
    /// Must be called with the lock held.
    private func deliverPendingInterrupts() {
        var toFire: [MSIXTableEntry] = []

        for vector in 0..<table.count {
            let wordIndex = vector / 64
            let bitIndex = vector % 64
            guard wordIndex < pba.count else { continue }

            let isPending = (pba[wordIndex] & (UInt64(1) << bitIndex)) != 0
            if isPending && !table[vector].isMasked {
                pba[wordIndex] &= ~(UInt64(1) << bitIndex)
                toFire.append(table[vector])
            }
        }

        // Release lock before firing to avoid deadlock with MSI controller.
        lock.unlock()
        for entry in toFire {
            fireInterrupt(entry: entry)
        }
        lock.lock()
    }
}
