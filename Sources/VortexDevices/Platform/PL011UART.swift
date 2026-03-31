// PL011UART.swift -- ARM PL011 UART serial console emulation.
// VortexDevices
//
// Emulates the ARM PrimeCell PL011 UART at the standard MMIO address.
// The guest uses this as its primary serial console (earlycon / ttyAMA0).
//
// Register map (offsets from base):
//   0x000  UARTDR     Data Register (read: RX FIFO, write: TX FIFO)
//   0x004  UARTRSR    Receive Status / Error Clear
//   0x018  UARTFR     Flag Register (read-only)
//   0x020  UARTILPR   IrDA Low-Power Counter (unused, RAZ/WI)
//   0x024  UARTIBRD   Integer Baud Rate Divisor
//   0x028  UARTFBRD   Fractional Baud Rate Divisor
//   0x02C  UARTLCR_H  Line Control Register
//   0x030  UARTCR     Control Register
//   0x034  UARTIFLS   Interrupt FIFO Level Select
//   0x038  UARTIMSC   Interrupt Mask Set/Clear
//   0x03C  UARTRIS    Raw Interrupt Status (read-only)
//   0x040  UARTMIS    Masked Interrupt Status (read-only)
//   0x044  UARTICR    Interrupt Clear (write-only)
//   0x048  UARTDMACR  DMA Control Register (unused, RAZ/WI)
//   0xFE0-0xFFF       PrimeCell Identification Registers

import Foundation
import VortexHV

// MARK: - PL011 Register Offsets

/// MMIO register offsets for the PL011 UART.
private enum PL011Reg {
    static let dr: UInt64       = 0x000  // Data Register
    static let rsr: UInt64      = 0x004  // Receive Status Register
    static let fr: UInt64       = 0x018  // Flag Register
    static let ilpr: UInt64     = 0x020  // IrDA Low-Power Counter
    static let ibrd: UInt64     = 0x024  // Integer Baud Rate Divisor
    static let fbrd: UInt64     = 0x028  // Fractional Baud Rate Divisor
    static let lcrH: UInt64     = 0x02C  // Line Control Register
    static let cr: UInt64       = 0x030  // Control Register
    static let ifls: UInt64     = 0x034  // Interrupt FIFO Level Select
    static let imsc: UInt64     = 0x038  // Interrupt Mask Set/Clear
    static let ris: UInt64      = 0x03C  // Raw Interrupt Status
    static let mis: UInt64      = 0x040  // Masked Interrupt Status
    static let icr: UInt64      = 0x044  // Interrupt Clear
    static let dmacr: UInt64    = 0x048  // DMA Control Register

    // PrimeCell ID registers (read-only)
    static let periphID0: UInt64 = 0xFE0  // 0x11
    static let periphID1: UInt64 = 0xFE4  // 0x10
    static let periphID2: UInt64 = 0xFE8  // 0x14 (rev 1, PL011)
    static let periphID3: UInt64 = 0xFEC  // 0x00
    static let cellID0: UInt64   = 0xFF0  // 0x0D
    static let cellID1: UInt64   = 0xFF4  // 0xF0
    static let cellID2: UInt64   = 0xFF8  // 0x05
    static let cellID3: UInt64   = 0xFFC  // 0xB1
}

// MARK: - Flag Register Bits

/// UARTFR (Flag Register) bit definitions.
private enum PL011Flag {
    static let txfe: UInt32 = 1 << 7   // Transmit FIFO empty
    static let rxff: UInt32 = 1 << 6   // Receive FIFO full
    static let txff: UInt32 = 1 << 5   // Transmit FIFO full
    static let rxfe: UInt32 = 1 << 4   // Receive FIFO empty
    static let busy: UInt32 = 1 << 3   // UART busy
}

// MARK: - Control Register Bits

/// UARTCR (Control Register) bit definitions.
private enum PL011Control {
    static let uarten: UInt32 = 1 << 0   // UART enable
    static let txe: UInt32    = 1 << 8   // Transmit enable
    static let rxe: UInt32    = 1 << 9   // Receive enable
}

// MARK: - Interrupt Bits

/// Interrupt bit positions (shared by IMSC, RIS, MIS, ICR).
private enum PL011Int {
    static let txis: UInt32 = 1 << 5   // Transmit interrupt
    static let rxis: UInt32 = 1 << 4   // Receive interrupt
    static let rtis: UInt32 = 1 << 6   // Receive timeout interrupt
    static let feis: UInt32 = 1 << 7   // Framing error interrupt
    static let peis: UInt32 = 1 << 8   // Parity error interrupt
    static let beis: UInt32 = 1 << 9   // Break error interrupt
    static let oeis: UInt32 = 1 << 10  // Overrun error interrupt
    static let allMask: UInt32 = 0x7FF // All interrupt bits [10:0]
}

// MARK: - PrimeCell ID Values

/// Standard PL011 PrimeCell identification register values.
private let pl011PeriphID: [UInt8] = [0x11, 0x10, 0x14, 0x00]
private let pl011CellID: [UInt8] = [0x0D, 0xF0, 0x05, 0xB1]

// MARK: - PL011 UART Device

/// ARM PL011 UART emulation implementing the MMIODevice protocol.
///
/// Provides a full PL011 register interface for guest serial console I/O.
/// Characters written by the guest to the Data Register are forwarded to an
/// output callback. Characters can be injected from the host into the receive
/// FIFO via ``injectCharacter(_:)`` or ``injectString(_:)``.
///
/// - Important: All MMIO accesses are serialized by an internal lock.
///   The output callback is invoked under the lock -- keep it fast.
///
/// ## Threading Model
/// - `mmioRead`/`mmioWrite` are called from the vCPU thread.
/// - `injectCharacter`/`injectString` may be called from any thread.
/// - The `onOutput` callback is invoked synchronously from the vCPU thread context.
/// - The `onInterruptStateChanged` callback is invoked from the vCPU thread or
///   whichever thread called `injectCharacter`.
public final class PL011UART: MMIODevice, @unchecked Sendable {

    // MARK: - MMIODevice Properties

    public let baseAddress: UInt64
    public let regionSize: UInt64 = MachineMemoryMap.uart0Size

    // MARK: - Callbacks

    /// Called when the guest writes a character to the TX data register.
    /// The parameter is the byte value written.
    public var onOutput: ((UInt8) -> Void)?

    /// Called whenever the interrupt state changes (asserted or deasserted).
    /// The parameter is `true` when any unmasked interrupt is active.
    /// Use this to call GIC setSPI to drive the UART interrupt line.
    public var onInterruptStateChanged: ((Bool) -> Void)?

    // MARK: - Internal State

    private let lock = NSLock()

    /// Receive FIFO -- characters waiting for the guest to read.
    /// PL011 has a 16-entry FIFO; we use a larger buffer for convenience.
    private var rxFIFO: [UInt8] = []
    private let rxFIFOCapacity = 256

    // Registers
    private var integerBaudRate: UInt32 = 0
    private var fractionalBaudRate: UInt32 = 0
    private var lineControl: UInt32 = 0
    private var controlRegister: UInt32 = PL011Control.txe | PL011Control.rxe
    private var interruptFIFOLevel: UInt32 = 0  // Default: 1/8 FIFO level
    private var interruptMask: UInt32 = 0       // No interrupts enabled initially
    private var rawInterruptStatus: UInt32 = 0
    private var receiveStatus: UInt32 = 0
    private var dmaCR: UInt32 = 0

    // MARK: - Initialization

    /// Create a PL011 UART device.
    ///
    /// - Parameter baseAddress: The MMIO base address in guest physical memory.
    ///   Defaults to the standard UART0 address from the machine memory map.
    public init(baseAddress: UInt64 = MachineMemoryMap.uart0Base) {
        self.baseAddress = baseAddress
    }

    // MARK: - Host Input Injection

    /// Inject a single character into the receive FIFO (host -> guest).
    ///
    /// If the FIFO is full, the character is silently dropped (matching PL011
    /// overrun behavior). An RX interrupt is raised if enabled.
    ///
    /// - Parameter byte: The character byte to inject.
    public func injectCharacter(_ byte: UInt8) {
        lock.lock()
        if rxFIFO.count < rxFIFOCapacity {
            rxFIFO.append(byte)
        }
        // Set RX interrupt status.
        rawInterruptStatus |= PL011Int.rxis
        let irqAsserted = updateInterruptLine()
        lock.unlock()

        if irqAsserted {
            onInterruptStateChanged?(true)
        }
    }

    /// Inject a string of characters into the receive FIFO (host -> guest).
    ///
    /// Each byte of the UTF-8 encoded string is injected individually.
    /// Characters beyond the FIFO capacity are silently dropped.
    ///
    /// - Parameter string: The string to inject.
    public func injectString(_ string: String) {
        let bytes = Array(string.utf8)
        lock.lock()
        for byte in bytes {
            if rxFIFO.count < rxFIFOCapacity {
                rxFIFO.append(byte)
            }
        }
        if !bytes.isEmpty {
            rawInterruptStatus |= PL011Int.rxis
        }
        let irqAsserted = updateInterruptLine()
        lock.unlock()

        if irqAsserted {
            onInterruptStateChanged?(true)
        }
    }

    /// Reset the UART to its power-on state.
    public func reset() {
        lock.lock()
        rxFIFO.removeAll()
        integerBaudRate = 0
        fractionalBaudRate = 0
        lineControl = 0
        controlRegister = PL011Control.txe | PL011Control.rxe
        interruptFIFOLevel = 0
        interruptMask = 0
        rawInterruptStatus = 0
        receiveStatus = 0
        dmaCR = 0
        lock.unlock()

        onInterruptStateChanged?(false)
    }

    // MARK: - MMIODevice Implementation

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        switch offset {
        case PL011Reg.dr:
            return UInt64(readDataRegister())

        case PL011Reg.rsr:
            return UInt64(receiveStatus)

        case PL011Reg.fr:
            return UInt64(readFlagRegister())

        case PL011Reg.ilpr:
            return 0 // IrDA not supported

        case PL011Reg.ibrd:
            return UInt64(integerBaudRate)

        case PL011Reg.fbrd:
            return UInt64(fractionalBaudRate)

        case PL011Reg.lcrH:
            return UInt64(lineControl)

        case PL011Reg.cr:
            return UInt64(controlRegister)

        case PL011Reg.ifls:
            return UInt64(interruptFIFOLevel)

        case PL011Reg.imsc:
            return UInt64(interruptMask)

        case PL011Reg.ris:
            return UInt64(rawInterruptStatus)

        case PL011Reg.mis:
            return UInt64(rawInterruptStatus & interruptMask)

        case PL011Reg.icr:
            return 0 // Write-only register

        case PL011Reg.dmacr:
            return UInt64(dmaCR)

        // PrimeCell peripheral identification registers
        case PL011Reg.periphID0:
            return UInt64(pl011PeriphID[0])
        case PL011Reg.periphID1:
            return UInt64(pl011PeriphID[1])
        case PL011Reg.periphID2:
            return UInt64(pl011PeriphID[2])
        case PL011Reg.periphID3:
            return UInt64(pl011PeriphID[3])
        case PL011Reg.cellID0:
            return UInt64(pl011CellID[0])
        case PL011Reg.cellID1:
            return UInt64(pl011CellID[1])
        case PL011Reg.cellID2:
            return UInt64(pl011CellID[2])
        case PL011Reg.cellID3:
            return UInt64(pl011CellID[3])

        default:
            return 0
        }
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()

        var notifyInterrupt = false

        switch offset {
        case PL011Reg.dr:
            writeDataRegister(UInt32(truncatingIfNeeded: value))

        case PL011Reg.rsr:
            // Writing any value clears the receive status/error flags.
            receiveStatus = 0

        case PL011Reg.ilpr:
            break // IrDA not supported, write-ignore

        case PL011Reg.ibrd:
            integerBaudRate = UInt32(truncatingIfNeeded: value) & 0xFFFF

        case PL011Reg.fbrd:
            fractionalBaudRate = UInt32(truncatingIfNeeded: value) & 0x3F

        case PL011Reg.lcrH:
            lineControl = UInt32(truncatingIfNeeded: value) & 0xFF
            // Writing LCR_H flushes the FIFOs (ARM DDI 0183G, 3.3.7).
            rxFIFO.removeAll()

        case PL011Reg.cr:
            controlRegister = UInt32(truncatingIfNeeded: value) & 0xFF87
            notifyInterrupt = updateInterruptLine()

        case PL011Reg.ifls:
            interruptFIFOLevel = UInt32(truncatingIfNeeded: value) & 0x3F
            notifyInterrupt = updateInterruptLine()

        case PL011Reg.imsc:
            interruptMask = UInt32(truncatingIfNeeded: value) & PL011Int.allMask
            notifyInterrupt = updateInterruptLine()

        case PL011Reg.icr:
            // Clear the specified interrupt bits.
            rawInterruptStatus &= ~(UInt32(truncatingIfNeeded: value) & PL011Int.allMask)
            notifyInterrupt = updateInterruptLine()

        case PL011Reg.dmacr:
            dmaCR = UInt32(truncatingIfNeeded: value) & 0x7

        default:
            break // Unknown register, write-ignore
        }

        let maskedActive = (rawInterruptStatus & interruptMask) != 0
        lock.unlock()

        if notifyInterrupt || !maskedActive {
            onInterruptStateChanged?(maskedActive)
        }
    }

    // MARK: - Private Register Logic

    /// Read from the Data Register: returns the next byte from the RX FIFO.
    /// If the FIFO is empty, returns 0 with no error status.
    private func readDataRegister() -> UInt32 {
        guard !rxFIFO.isEmpty else {
            return 0
        }
        let byte = rxFIFO.removeFirst()

        // Clear the RX interrupt if FIFO is now empty.
        if rxFIFO.isEmpty {
            rawInterruptStatus &= ~PL011Int.rxis
        }

        return UInt32(byte)
    }

    /// Write to the Data Register: transmit a character.
    private func writeDataRegister(_ value: UInt32) {
        guard (controlRegister & PL011Control.uarten) != 0,
              (controlRegister & PL011Control.txe) != 0 else {
            return // UART or TX not enabled
        }

        let byte = UInt8(truncatingIfNeeded: value)

        // TX is instantaneous in emulation -- set the TX empty interrupt.
        rawInterruptStatus |= PL011Int.txis

        // Release the lock briefly to invoke the output callback,
        // since it may do blocking I/O (writing to a terminal, etc.).
        // We already hold the lock from mmioWrite, so we call the callback
        // after the write handler completes. Store the byte to output.
        lock.unlock()
        onOutput?(byte)
        lock.lock()
    }

    /// Compute the flag register value from current state.
    private func readFlagRegister() -> UInt32 {
        var flags: UInt32 = 0

        // TX is always "empty" and never "full" in our emulation
        // (transmit is instantaneous).
        flags |= PL011Flag.txfe

        // RX FIFO state
        if rxFIFO.isEmpty {
            flags |= PL011Flag.rxfe
        }
        if rxFIFO.count >= rxFIFOCapacity {
            flags |= PL011Flag.rxff
        }

        return flags
    }

    /// Evaluate whether the interrupt output line should be asserted.
    /// Returns `true` if the state changed to active (any masked interrupt pending).
    @discardableResult
    private func updateInterruptLine() -> Bool {
        return (rawInterruptStatus & interruptMask) != 0
    }
}
