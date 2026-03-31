// GICv3Distributor.swift -- Software-emulated GICv3 Distributor (GICD).
// VortexHV
//
// Implements the MMIO interface for the GIC Distributor when the HV-assisted
// GIC is not available (macOS 14). This handles SPI routing, enable/disable,
// priority, and configuration registers.

import Foundation

// MARK: - GICD Register Offsets

private enum GICDReg {
    static let CTLR:            UInt64 = 0x0000
    static let TYPER:           UInt64 = 0x0004
    static let IIDR:            UInt64 = 0x0008
    static let STATUSR:         UInt64 = 0x0010
    static let SETSPI_NSR:      UInt64 = 0x0040
    static let CLRSPI_NSR:      UInt64 = 0x0048
    static let IGROUPR_BASE:    UInt64 = 0x0080
    static let ISENABLER_BASE:  UInt64 = 0x0100
    static let ICENABLER_BASE:  UInt64 = 0x0180
    static let ISPENDR_BASE:    UInt64 = 0x0200
    static let ICPENDR_BASE:    UInt64 = 0x0280
    static let ISACTIVER_BASE:  UInt64 = 0x0300
    static let ICACTIVER_BASE:  UInt64 = 0x0380
    static let IPRIORITYR_BASE: UInt64 = 0x0400
    static let ITARGETSR_BASE:  UInt64 = 0x0800
    static let ICFGR_BASE:      UInt64 = 0x0C00
    static let IROUTER_BASE:    UInt64 = 0x6000
    static let PIDR2:           UInt64 = 0xFFE8
}

// MARK: - GICv3 Distributor

/// Software-emulated GICv3 Distributor for MMIO-based interrupt management.
///
/// The distributor manages Shared Peripheral Interrupts (SPIs, INTIDs 32-1019).
/// SGIs (0-15) and PPIs (16-31) are managed by each redistributor.
public final class GICv3Distributor: MMIODevice, @unchecked Sendable {
    public let baseAddress: UInt64
    public let regionSize: UInt64 = 0x10000 // 64 KiB

    /// Number of SPIs supported.
    public let spiCount: Int

    /// Total number of interrupt lines (SGIs + PPIs + SPIs).
    private var intCount: Int { 32 + spiCount }
    /// Number of 32-bit register banks needed.
    private var bankCount: Int { (intCount + 31) / 32 }

    // Register state
    private let lock = NSLock()
    private var ctlr: UInt32 = 0
    private var enableBits: [UInt32]     // ISENABLER/ICENABLER
    private var pendingBits: [UInt32]    // ISPENDR/ICPENDR
    private var activeBits: [UInt32]     // ISACTIVER/ICACTIVER
    private var priorityRegs: [UInt8]    // IPRIORITYR (one byte per interrupt)
    private var configRegs: [UInt32]     // ICFGR (2 bits per interrupt)
    private var groupBits: [UInt32]      // IGROUPR
    private var routerRegs: [UInt64]     // IROUTER (one per SPI)

    /// Callback: notify that an SPI is now pending and should be delivered.
    /// Parameters: INTID, target affinity.
    public var onSPIPending: ((UInt32, UInt64) -> Void)?

    public init(baseAddress: UInt64, spiCount: Int) {
        self.baseAddress = baseAddress
        self.spiCount = spiCount
        let banks = (32 + spiCount + 31) / 32
        let totalInts = 32 + spiCount

        enableBits = Array(repeating: 0, count: banks)
        pendingBits = Array(repeating: 0, count: banks)
        activeBits = Array(repeating: 0, count: banks)
        priorityRegs = Array(repeating: 0, count: totalInts)
        configRegs = Array(repeating: 0, count: (totalInts + 15) / 16)
        groupBits = Array(repeating: 0, count: banks)
        routerRegs = Array(repeating: 0, count: max(spiCount, 1))
    }

    // MARK: - SPI Control

    /// Set the level of an SPI. For edge-triggered, set level=true to assert.
    public func setSPI(intid: UInt32, level: Bool) {
        guard intid >= 32 && intid < 32 + UInt32(spiCount) else { return }
        lock.lock()
        let bank = Int(intid) / 32
        let bit: UInt32 = 1 << (intid % 32)

        if level {
            pendingBits[bank] |= bit
        } else {
            pendingBits[bank] &= ~bit
        }

        let isPending = (pendingBits[bank] & bit) != 0
        let isEnabled = (enableBits[bank] & bit) != 0
        let router = routerRegs[Int(intid) - 32]
        lock.unlock()

        if isPending && isEnabled {
            onSPIPending?(intid, router)
        }
    }

    /// Reset all distributor state.
    public func reset() {
        lock.lock()
        ctlr = 0
        enableBits = Array(repeating: 0, count: enableBits.count)
        pendingBits = Array(repeating: 0, count: pendingBits.count)
        activeBits = Array(repeating: 0, count: activeBits.count)
        priorityRegs = Array(repeating: 0, count: priorityRegs.count)
        configRegs = Array(repeating: 0, count: configRegs.count)
        groupBits = Array(repeating: 0, count: groupBits.count)
        routerRegs = Array(repeating: 0, count: routerRegs.count)
        lock.unlock()
    }

    // MARK: - MMIO Interface

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case GICDReg.CTLR:
            return UInt64(ctlr)

        case GICDReg.TYPER:
            // ITLinesNumber = (spiCount / 32) - 1, CPUNumber = 0 (affinity routing)
            let itLines = UInt32(max(spiCount / 32, 1) - 1) & 0x1F
            let typer: UInt32 = itLines | (1 << 24) // ARE_NS = 1
            return UInt64(typer)

        case GICDReg.IIDR:
            return 0x0100_043B // ARM GICv3 implementer

        case GICDReg.PIDR2:
            return 0x3B // GICv3 architecture revision

        default:
            break
        }

        // IGROUPR
        if let bank = bankIndex(offset: offset, base: GICDReg.IGROUPR_BASE, stride: 4) {
            return UInt64(groupBits[bank])
        }

        // ISENABLER
        if let bank = bankIndex(offset: offset, base: GICDReg.ISENABLER_BASE, stride: 4) {
            return UInt64(enableBits[bank])
        }

        // ICENABLER
        if let bank = bankIndex(offset: offset, base: GICDReg.ICENABLER_BASE, stride: 4) {
            return UInt64(enableBits[bank])
        }

        // ISPENDR
        if let bank = bankIndex(offset: offset, base: GICDReg.ISPENDR_BASE, stride: 4) {
            return UInt64(pendingBits[bank])
        }

        // ICPENDR
        if let bank = bankIndex(offset: offset, base: GICDReg.ICPENDR_BASE, stride: 4) {
            return UInt64(pendingBits[bank])
        }

        // ISACTIVER
        if let bank = bankIndex(offset: offset, base: GICDReg.ISACTIVER_BASE, stride: 4) {
            return UInt64(activeBits[bank])
        }

        // IPRIORITYR (byte-accessible)
        if offset >= GICDReg.IPRIORITYR_BASE && offset < GICDReg.IPRIORITYR_BASE + UInt64(intCount) {
            let intid = Int(offset - GICDReg.IPRIORITYR_BASE)
            if size == 4 && intid + 3 < priorityRegs.count {
                var val: UInt32 = 0
                for i in 0..<4 {
                    val |= UInt32(priorityRegs[intid + i]) << (i * 8)
                }
                return UInt64(val)
            }
            if intid < priorityRegs.count {
                return UInt64(priorityRegs[intid])
            }
        }

        // ICFGR
        if let bank = bankIndex(offset: offset, base: GICDReg.ICFGR_BASE, stride: 4) {
            if bank < configRegs.count {
                return UInt64(configRegs[bank])
            }
        }

        // IROUTER
        if offset >= GICDReg.IROUTER_BASE {
            let spiIndex = Int((offset - GICDReg.IROUTER_BASE) / 8)
            if spiIndex < routerRegs.count {
                return routerRegs[spiIndex]
            }
        }

        return 0
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case GICDReg.CTLR:
            ctlr = UInt32(truncatingIfNeeded: value)
            return

        case GICDReg.SETSPI_NSR:
            let intid = UInt32(value & 0x3FF)
            if intid >= 32 && intid < 32 + UInt32(spiCount) {
                let bank = Int(intid) / 32
                pendingBits[bank] |= (1 << (intid % 32))
            }
            return

        case GICDReg.CLRSPI_NSR:
            let intid = UInt32(value & 0x3FF)
            if intid >= 32 && intid < 32 + UInt32(spiCount) {
                let bank = Int(intid) / 32
                pendingBits[bank] &= ~(1 << (intid % 32))
            }
            return

        default:
            break
        }

        // IGROUPR
        if let bank = bankIndex(offset: offset, base: GICDReg.IGROUPR_BASE, stride: 4) {
            groupBits[bank] = UInt32(truncatingIfNeeded: value)
            return
        }

        // ISENABLER (set-enable: write 1 to set bits)
        if let bank = bankIndex(offset: offset, base: GICDReg.ISENABLER_BASE, stride: 4) {
            enableBits[bank] |= UInt32(truncatingIfNeeded: value)
            return
        }

        // ICENABLER (clear-enable: write 1 to clear bits)
        if let bank = bankIndex(offset: offset, base: GICDReg.ICENABLER_BASE, stride: 4) {
            enableBits[bank] &= ~UInt32(truncatingIfNeeded: value)
            return
        }

        // ISPENDR
        if let bank = bankIndex(offset: offset, base: GICDReg.ISPENDR_BASE, stride: 4) {
            pendingBits[bank] |= UInt32(truncatingIfNeeded: value)
            return
        }

        // ICPENDR
        if let bank = bankIndex(offset: offset, base: GICDReg.ICPENDR_BASE, stride: 4) {
            pendingBits[bank] &= ~UInt32(truncatingIfNeeded: value)
            return
        }

        // ISACTIVER
        if let bank = bankIndex(offset: offset, base: GICDReg.ISACTIVER_BASE, stride: 4) {
            activeBits[bank] |= UInt32(truncatingIfNeeded: value)
            return
        }

        // ICACTIVER
        if let bank = bankIndex(offset: offset, base: GICDReg.ICACTIVER_BASE, stride: 4) {
            activeBits[bank] &= ~UInt32(truncatingIfNeeded: value)
            return
        }

        // IPRIORITYR
        if offset >= GICDReg.IPRIORITYR_BASE && offset < GICDReg.IPRIORITYR_BASE + UInt64(intCount) {
            let intid = Int(offset - GICDReg.IPRIORITYR_BASE)
            if size == 4 && intid + 3 < priorityRegs.count {
                let val = UInt32(truncatingIfNeeded: value)
                for i in 0..<4 {
                    priorityRegs[intid + i] = UInt8((val >> (i * 8)) & 0xFF)
                }
            } else if intid < priorityRegs.count {
                priorityRegs[intid] = UInt8(value & 0xFF)
            }
            return
        }

        // ICFGR
        if let bank = bankIndex(offset: offset, base: GICDReg.ICFGR_BASE, stride: 4) {
            if bank < configRegs.count {
                configRegs[bank] = UInt32(truncatingIfNeeded: value)
            }
            return
        }

        // IROUTER
        if offset >= GICDReg.IROUTER_BASE {
            let spiIndex = Int((offset - GICDReg.IROUTER_BASE) / 8)
            if spiIndex < routerRegs.count {
                routerRegs[spiIndex] = value
            }
            return
        }
    }

    // MARK: - Helpers

    private func bankIndex(offset: UInt64, base: UInt64, stride: UInt64) -> Int? {
        guard offset >= base else { return nil }
        let idx = Int((offset - base) / stride)
        guard idx < bankCount else { return nil }
        // Verify the offset is properly aligned to the stride.
        guard (offset - base) % stride == 0 else { return nil }
        return idx
    }
}
