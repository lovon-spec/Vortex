// MSIController.swift -- MSI/MSI-X support for PCI devices.
// VortexHV
//
// Provides an MMIO target for PCI devices to send Message Signaled Interrupts.
// The MSI controller translates MSI writes into GIC SPI assertions,
// either via the HV-assisted GIC or software emulation.

import Foundation
import Hypervisor

// MARK: - MSI Controller

/// Handles MSI/MSI-X doorbell writes from PCI devices.
///
/// PCI devices write to an MMIO doorbell address to signal an MSI. This controller
/// decodes the write and routes it as a GIC SPI.
///
/// Register layout (compatible with GICv3 ITS-less MSI / GICv2m):
/// - Offset 0x000: SETSPI_NSR -- write INTID to trigger SPI
/// - Offset 0x040: TYPER -- read-only type register
public final class MSIController: MMIODevice, @unchecked Sendable {
    public let baseAddress: UInt64
    public let regionSize: UInt64 = 0x1000 // 4 KiB

    /// The SPI INTID base for MSI interrupts.
    public let spiBase: UInt32
    /// Number of MSI SPIs available.
    public let spiCount: UInt32
    /// Whether to use HV-assisted GIC for MSI delivery.
    public let useHVGIC: Bool

    // Track which MSI vectors are allocated.
    private let lock = NSLock()
    private var allocatedVectors: Set<UInt32> = []

    /// Callback for software-emulated path: deliver SPI.
    public var onMSIFired: ((UInt32) -> Void)?

    public init(
        baseAddress: UInt64,
        spiBase: UInt32,
        spiCount: UInt32,
        useHVGIC: Bool
    ) {
        self.baseAddress = baseAddress
        self.spiBase = spiBase
        self.spiCount = spiCount
        self.useHVGIC = useHVGIC
    }

    /// Allocate an MSI vector. Returns the INTID or nil if exhausted.
    public func allocateVector() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<spiCount {
            let intid = spiBase + i
            if !allocatedVectors.contains(intid) {
                allocatedVectors.insert(intid)
                return intid
            }
        }
        return nil
    }

    /// Free a previously allocated MSI vector.
    public func freeVector(_ intid: UInt32) {
        lock.lock()
        allocatedVectors.remove(intid)
        lock.unlock()
    }

    /// Get the doorbell address that a PCI device should write to for MSI.
    /// The device writes the INTID to this address.
    public var doorbellAddress: UInt64 {
        baseAddress // SETSPI_NSR at offset 0
    }

    /// Get the data value for an MSI with the given INTID.
    public func msiData(for intid: UInt32) -> UInt32 {
        intid
    }

    // MARK: - MMIO Interface

    public func mmioRead(offset: UInt64, size: Int) -> UInt64 {
        switch offset {
        case 0x040: // TYPER
            // Report the SPI base and count.
            return UInt64(spiBase) | (UInt64(spiCount) << 16)
        default:
            return 0
        }
    }

    public func mmioWrite(offset: UInt64, size: Int, value: UInt64) {
        switch offset {
        case 0x000: // SETSPI_NSR -- trigger SPI
            let intid = UInt32(value & 0x3FF)
            guard intid >= spiBase && intid < spiBase + spiCount else { return }
            fireMSI(intid: intid)

        case 0x008: // CLRSPI_NSR -- clear SPI (for level-sensitive MSIs)
            let intid = UInt32(value & 0x3FF)
            guard intid >= spiBase && intid < spiBase + spiCount else { return }
            clearMSI(intid: intid)

        default:
            break
        }
    }

    // MARK: - Private

    private func fireMSI(intid: UInt32) {
        if useHVGIC {
            if #available(macOS 15.0, *) {
                _ = hv_gic_send_msi(baseAddress, intid)
            }
        } else {
            onMSIFired?(intid)
        }
    }

    private func clearMSI(intid: UInt32) {
        if useHVGIC {
            if #available(macOS 15.0, *) {
                _ = hv_gic_set_spi(intid, false)
            }
        }
        // Software path: the distributor handles clearing via ICPENDR.
    }
}
