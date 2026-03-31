// GICv3Redistributor.swift -- Software-emulated GICv3 Redistributor (GICR).
// VortexHV
//
// Each vCPU has its own redistributor that manages SGIs (0-15) and PPIs (16-31).
// The redistributor occupies two 64 KiB frames:
//   - Frame 0 (RD_base): Control and identification registers
//   - Frame 1 (SGI_base): SGI and PPI configuration registers

import Foundation

// MARK: - GICR Register Offsets

private enum GICRReg {
    // Frame 0: RD_base
    static let CTLR:        UInt64 = 0x0000
    static let IIDR:        UInt64 = 0x0004
    static let TYPER:       UInt64 = 0x0008  // 64-bit
    static let STATUSR:     UInt64 = 0x0010
    static let WAKER:       UInt64 = 0x0014
    static let PIDR2:       UInt64 = 0xFFE8

    // Frame 1: SGI_base (offset 0x10000 from RD_base)
    static let SGI_OFFSET:      UInt64 = 0x10000
    static let IGROUPR0:        UInt64 = 0x10080
    static let ISENABLER0:      UInt64 = 0x10100
    static let ICENABLER0:      UInt64 = 0x10180
    static let ISPENDR0:        UInt64 = 0x10200
    static let ICPENDR0:        UInt64 = 0x10280
    static let ISACTIVER0:      UInt64 = 0x10300
    static let ICACTIVER0:      UInt64 = 0x10380
    static let IPRIORITYR_BASE: UInt64 = 0x10400
    static let ICFGR0:          UInt64 = 0x10C00
    static let ICFGR1:          UInt64 = 0x10C04
}

// MARK: - GICv3 Redistributor

/// Software-emulated GICv3 Redistributor for a single vCPU.
///
/// Manages SGIs (0-15) and PPIs (16-31) for its associated CPU.
public final class GICv3Redistributor: MMIODevice, @unchecked Sendable {
    public let baseAddress: UInt64
    public let regionSize: UInt64 = 0x20000 // Two 64 KiB frames

    /// CPU index this redistributor belongs to.
    public let cpuIndex: Int
    /// Whether this is the last redistributor in the chain.
    public let isLast: Bool

    // Register state (covers INTIDs 0-31)
    private let lock = NSLock()
    private var ctlr: UInt32 = 0
    private var waker: UInt32 = 0x0000_0002 // ProcessorSleep = 1 initially
    private var groupBits: UInt32 = 0
    private var enableBits: UInt32 = 0
    private var pendingBits: UInt32 = 0
    private var activeBits: UInt32 = 0
    private var priorityRegs: [UInt8] = Array(repeating: 0, count: 32)
    private var cfgReg0: UInt32 = 0  // ICFGR0 (SGIs, always edge-triggered)
    private var cfgReg1: UInt32 = 0  // ICFGR1 (PPIs)

    /// Callback: notify that a private interrupt is pending on this CPU.
    /// Parameter: INTID (0-31)
    public var onPrivateInterruptPending: ((UInt32) -> Void)?

    public init(baseAddress: UInt64, cpuIndex: Int, isLast: Bool) {
        self.baseAddress = baseAddress
        self.cpuIndex = cpuIndex
        self.isLast = isLast
    }

    /// Set an SGI as pending (used by sendSGI).
    public func setPendingSGI(intid: UInt32) {
        guard intid < 16 else { return }
        lock.lock()
        pendingBits |= (1 << intid)
        let isEnabled = (enableBits & (1 << intid)) != 0
        lock.unlock()
        if isEnabled {
            onPrivateInterruptPending?(intid)
        }
    }

    /// Set a PPI as pending.
    public func setPendingPPI(intid: UInt32) {
        guard intid >= 16 && intid < 32 else { return }
        lock.lock()
        pendingBits |= (1 << intid)
        let isEnabled = (enableBits & (1 << intid)) != 0
        lock.unlock()
        if isEnabled {
            onPrivateInterruptPending?(intid)
        }
    }

    /// Reset all redistributor state.
    public func reset() {
        lock.lock()
        ctlr = 0
        waker = 0x0000_0002
        groupBits = 0
        enableBits = 0
        pendingBits = 0
        activeBits = 0
        priorityRegs = Array(repeating: 0, count: 32)
        cfgReg0 = 0
        cfgReg1 = 0
        lock.unlock()
    }

    // MARK: - MMIO Interface

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        // Frame 0 registers
        case GICRReg.CTLR:
            return UInt64(ctlr)

        case GICRReg.IIDR:
            return 0x0100_043B // ARM GICv3

        case GICRReg.TYPER:
            // Affinity = cpuIndex, Last = isLast bit
            var typer: UInt64 = UInt64(cpuIndex) << 8  // Affinity_Value in bits [31:8]
            if isLast { typer |= (1 << 4) }  // Last bit
            // Processor_Number
            typer |= UInt64(cpuIndex) << 8
            return typer

        case GICRReg.TYPER + 4:
            // Upper 32 bits of TYPER (Affinity3, Affinity2).
            return 0

        case GICRReg.WAKER:
            return UInt64(waker)

        case GICRReg.PIDR2:
            return 0x3B // GICv3

        // Frame 1 (SGI_base) registers
        case GICRReg.IGROUPR0:
            return UInt64(groupBits)

        case GICRReg.ISENABLER0, GICRReg.ICENABLER0:
            return UInt64(enableBits)

        case GICRReg.ISPENDR0, GICRReg.ICPENDR0:
            return UInt64(pendingBits)

        case GICRReg.ISACTIVER0:
            return UInt64(activeBits)

        case GICRReg.ICACTIVER0:
            return UInt64(activeBits)

        case GICRReg.ICFGR0:
            return UInt64(cfgReg0)

        case GICRReg.ICFGR1:
            return UInt64(cfgReg1)

        default:
            break
        }

        // IPRIORITYR (bytes, 32 interrupts)
        if offset >= GICRReg.IPRIORITYR_BASE && offset < GICRReg.IPRIORITYR_BASE + 32 {
            let intid = Int(offset - GICRReg.IPRIORITYR_BASE)
            if size == 4 && intid + 3 < 32 {
                var val: UInt32 = 0
                for i in 0..<4 {
                    val |= UInt32(priorityRegs[intid + i]) << (i * 8)
                }
                return UInt64(val)
            }
            if intid < 32 {
                return UInt64(priorityRegs[intid])
            }
        }

        return 0
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case GICRReg.CTLR:
            ctlr = UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.WAKER:
            // Guest clears ProcessorSleep (bit 1) to wake up the redistributor.
            waker = UInt32(truncatingIfNeeded: value) & 0x6
            // When ProcessorSleep is cleared, clear ChildrenAsleep (bit 2).
            if (waker & 0x2) == 0 {
                waker &= ~UInt32(0x4) // Clear ChildrenAsleep
            }
            return

        // Frame 1 registers
        case GICRReg.IGROUPR0:
            groupBits = UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ISENABLER0:
            enableBits |= UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ICENABLER0:
            enableBits &= ~UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ISPENDR0:
            pendingBits |= UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ICPENDR0:
            pendingBits &= ~UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ISACTIVER0:
            activeBits |= UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ICACTIVER0:
            activeBits &= ~UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ICFGR0:
            cfgReg0 = UInt32(truncatingIfNeeded: value)
            return

        case GICRReg.ICFGR1:
            cfgReg1 = UInt32(truncatingIfNeeded: value)
            return

        default:
            break
        }

        // IPRIORITYR
        if offset >= GICRReg.IPRIORITYR_BASE && offset < GICRReg.IPRIORITYR_BASE + 32 {
            let intid = Int(offset - GICRReg.IPRIORITYR_BASE)
            if size == 4 && intid + 3 < 32 {
                let val = UInt32(truncatingIfNeeded: value)
                for i in 0..<4 {
                    priorityRegs[intid + i] = UInt8((val >> (i * 8)) & 0xFF)
                }
            } else if intid < 32 {
                priorityRegs[intid] = UInt8(value & 0xFF)
            }
            return
        }
    }
}
