// RTC.swift -- ARM PL031 Real Time Clock emulation.
// VortexDevices
//
// Emulates the ARM PrimeCell PL031 RTC at the standard MMIO address.
// Provides the guest with wall-clock time derived from the host system clock.
//
// Register map (offsets from base):
//   0x000  RTCDR   Data Register (read-only, current time in seconds since epoch)
//   0x004  RTCMR   Match Register (read/write, triggers interrupt when DR == MR)
//   0x008  RTCLR   Load Register (write-only, sets the RTC counter base)
//   0x00C  RTCCR   Control Register (bit 0: RTC enable)
//   0x010  RTCIMSC Interrupt Mask Set/Clear
//   0x014  RTCRIS  Raw Interrupt Status (read-only)
//   0x018  RTCMIS  Masked Interrupt Status (read-only)
//   0x01C  RTCICR  Interrupt Clear (write-only)
//   0xFE0-0xFFF    PrimeCell Identification Registers

import Foundation
import VortexHV

// MARK: - PL031 Register Offsets

private enum PL031Reg {
    static let dr: UInt64    = 0x000  // Data Register (current time)
    static let mr: UInt64    = 0x004  // Match Register
    static let lr: UInt64    = 0x008  // Load Register
    static let cr: UInt64    = 0x00C  // Control Register
    static let imsc: UInt64  = 0x010  // Interrupt Mask Set/Clear
    static let ris: UInt64   = 0x014  // Raw Interrupt Status
    static let mis: UInt64   = 0x018  // Masked Interrupt Status
    static let icr: UInt64   = 0x01C  // Interrupt Clear

    // PrimeCell ID registers
    static let periphID0: UInt64 = 0xFE0  // 0x31
    static let periphID1: UInt64 = 0xFE4  // 0x10
    static let periphID2: UInt64 = 0xFE8  // 0x04
    static let periphID3: UInt64 = 0xFEC  // 0x00
    static let cellID0: UInt64   = 0xFF0  // 0x0D
    static let cellID1: UInt64   = 0xFF4  // 0xF0
    static let cellID2: UInt64   = 0xFF8  // 0x05
    static let cellID3: UInt64   = 0xFFC  // 0xB1
}

// MARK: - PrimeCell ID Values

/// Standard PL031 PrimeCell identification register values.
private let pl031PeriphID: [UInt8] = [0x31, 0x10, 0x04, 0x00]
private let pl031CellID: [UInt8] = [0x0D, 0xF0, 0x05, 0xB1]

// MARK: - PL031 RTC Device

/// ARM PL031 Real Time Clock emulation implementing the MMIODevice protocol.
///
/// The RTC provides the guest with wall-clock time. The current time is computed
/// as: `loadOffset + secondsSinceLoad`, where `loadOffset` is set via the Load
/// Register (LR) and defaults to the host epoch time at device creation.
///
/// An optional match register triggers an interrupt when the counter equals the
/// match value.
///
/// ## Threading Model
/// - `mmioRead`/`mmioWrite` are called from the vCPU thread.
/// - The `onInterruptStateChanged` callback is invoked synchronously from the
///   vCPU thread context.
public final class PL031RTC: MMIODevice, @unchecked Sendable {

    // MARK: - MMIODevice Properties

    public let baseAddress: UInt64
    public let regionSize: UInt64 = MachineMemoryMap.rtcSize

    // MARK: - Callbacks

    /// Called whenever the interrupt state changes (asserted or deasserted).
    /// The parameter is `true` when any unmasked interrupt is active.
    /// Use this to call GIC setSPI to drive the RTC interrupt line.
    public var onInterruptStateChanged: ((Bool) -> Void)?

    // MARK: - Internal State

    private let lock = NSLock()

    /// The base epoch offset, initially set to the host time at creation.
    /// Writing the Load Register (LR) updates this value.
    private var loadOffset: UInt32

    /// The host `Date` at which `loadOffset` was established.
    /// Used to compute elapsed time: currentTime = loadOffset + (now - loadTimestamp).
    private var loadTimestamp: TimeInterval

    /// Match register -- triggers interrupt when counter == match.
    private var matchRegister: UInt32 = 0

    /// Control register -- bit 0 enables the RTC (always starts enabled).
    private var controlRegister: UInt32 = 1

    /// Interrupt mask -- bit 0 enables the match interrupt.
    private var interruptMask: UInt32 = 0

    /// Raw interrupt status -- bit 0 set when counter matches MR.
    private var rawInterruptStatus: UInt32 = 0

    /// Time source closure, injectable for testing.
    /// Returns the current epoch time in seconds as a `TimeInterval`.
    private let timeSource: () -> TimeInterval

    // MARK: - Initialization

    /// Create a PL031 RTC device.
    ///
    /// - Parameters:
    ///   - baseAddress: The MMIO base address in guest physical memory.
    ///     Defaults to the standard RTC address from the machine memory map.
    ///   - timeSource: A closure that returns the current time as seconds since
    ///     the Unix epoch. Defaults to `Date().timeIntervalSince1970`. Override
    ///     this in tests for deterministic behavior.
    public init(
        baseAddress: UInt64 = MachineMemoryMap.rtcBase,
        timeSource: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.baseAddress = baseAddress
        self.timeSource = timeSource
        let now = timeSource()
        self.loadOffset = UInt32(truncatingIfNeeded: UInt64(now))
        self.loadTimestamp = now
    }

    /// Reset the RTC to its power-on state, reloading from the host clock.
    public func reset() {
        lock.lock()
        let now = timeSource()
        loadOffset = UInt32(truncatingIfNeeded: UInt64(now))
        loadTimestamp = now
        matchRegister = 0
        controlRegister = 1
        interruptMask = 0
        rawInterruptStatus = 0
        lock.unlock()

        onInterruptStateChanged?(false)
    }

    // MARK: - MMIODevice Implementation

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case PL031Reg.dr:
            return UInt64(currentTime())

        case PL031Reg.mr:
            return UInt64(matchRegister)

        case PL031Reg.lr:
            return UInt64(loadOffset)

        case PL031Reg.cr:
            return UInt64(controlRegister)

        case PL031Reg.imsc:
            return UInt64(interruptMask)

        case PL031Reg.ris:
            return UInt64(rawInterruptStatus)

        case PL031Reg.mis:
            return UInt64(rawInterruptStatus & interruptMask)

        case PL031Reg.icr:
            return 0 // Write-only register

        // PrimeCell peripheral identification registers
        case PL031Reg.periphID0:
            return UInt64(pl031PeriphID[0])
        case PL031Reg.periphID1:
            return UInt64(pl031PeriphID[1])
        case PL031Reg.periphID2:
            return UInt64(pl031PeriphID[2])
        case PL031Reg.periphID3:
            return UInt64(pl031PeriphID[3])
        case PL031Reg.cellID0:
            return UInt64(pl031CellID[0])
        case PL031Reg.cellID1:
            return UInt64(pl031CellID[1])
        case PL031Reg.cellID2:
            return UInt64(pl031CellID[2])
        case PL031Reg.cellID3:
            return UInt64(pl031CellID[3])

        default:
            return 0
        }
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()

        switch offset {
        case PL031Reg.mr:
            matchRegister = UInt32(truncatingIfNeeded: value)

        case PL031Reg.lr:
            // Setting the load register resets the counter base.
            loadOffset = UInt32(truncatingIfNeeded: value)
            loadTimestamp = timeSource()

        case PL031Reg.cr:
            // Only bit 0 (RTC start) is writable, and per the PL031 spec
            // the RTC cannot be stopped once started. We allow the write
            // but always keep bit 0 set.
            controlRegister = UInt32(truncatingIfNeeded: value) | 1

        case PL031Reg.imsc:
            interruptMask = UInt32(truncatingIfNeeded: value) & 1
            let irqActive = (rawInterruptStatus & interruptMask) != 0
            lock.unlock()
            onInterruptStateChanged?(irqActive)
            return

        case PL031Reg.icr:
            rawInterruptStatus &= ~(UInt32(truncatingIfNeeded: value) & 1)
            let irqActive = (rawInterruptStatus & interruptMask) != 0
            lock.unlock()
            onInterruptStateChanged?(irqActive)
            return

        default:
            break // Unknown or read-only register, write-ignore
        }

        lock.unlock()
    }

    // MARK: - Private

    /// Compute the current RTC time value.
    /// Returns loadOffset plus elapsed seconds since the load was set.
    private func currentTime() -> UInt32 {
        let now = timeSource()
        let elapsed = now - loadTimestamp
        let elapsedSeconds = UInt32(truncatingIfNeeded: UInt64(max(0, elapsed)))
        return loadOffset &+ elapsedSeconds
    }

    /// Check and update the match interrupt.
    /// Call this periodically (e.g., from a timer) if match interrupts are needed.
    /// For basic RTC usage (reading time), the match interrupt is rarely used.
    public func checkMatchInterrupt() {
        lock.lock()
        let time = currentTime()
        if time == matchRegister {
            rawInterruptStatus |= 1
        }
        let irqActive = (rawInterruptStatus & interruptMask) != 0
        lock.unlock()

        onInterruptStateChanged?(irqActive)
    }
}
