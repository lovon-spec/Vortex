// AddressSpace.swift -- MMIO region registry and dispatch.
// VortexHV

import Foundation

// MARK: - MMIO Device Protocol

/// Protocol for devices that respond to memory-mapped I/O reads and writes.
public protocol MMIODevice: AnyObject, Sendable {
    /// The base guest physical address of this device.
    var baseAddress: UInt64 { get }
    /// The size in bytes of this device's MMIO region.
    var regionSize: UInt64 { get }
    /// Handle a read at the given offset within the device region.
    func mmioRead(offset: UInt64, size: Int) -> UInt64
    /// Handle a write at the given offset within the device region.
    func mmioWrite(offset: UInt64, size: Int, value: UInt64)
}

// MARK: - MMIO Region

/// A registered MMIO region binding an address range to a device.
public struct MMIORegion: Sendable {
    public let baseAddress: UInt64
    public let size: UInt64
    public let device: any MMIODevice

    public var endAddress: UInt64 { baseAddress &+ size }

    public func contains(address: UInt64) -> Bool {
        address >= baseAddress && address < endAddress
    }
}

// MARK: - Address Space

/// Manages the guest physical address space MMIO device mappings.
///
/// When a vCPU takes a data abort on an unmapped guest physical address,
/// the exit handler queries `AddressSpace` to find the target device
/// and dispatches the read or write.
public final class AddressSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var regions: [MMIORegion] = []

    public init() {}

    /// Register an MMIO device.
    /// - Parameter device: The device conforming to `MMIODevice`.
    /// - Throws: If the region overlaps an existing registration.
    public func registerDevice(_ device: any MMIODevice) throws {
        let newRegion = MMIORegion(
            baseAddress: device.baseAddress,
            size: device.regionSize,
            device: device
        )
        lock.lock()
        defer { lock.unlock() }
        for existing in regions {
            if regionsOverlap(existing, newRegion) {
                throw AddressSpaceError.regionOverlap(
                    existingBase: existing.baseAddress,
                    newBase: newRegion.baseAddress
                )
            }
        }
        regions.append(newRegion)
    }

    /// Unregister all devices.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        regions.removeAll()
    }

    /// Find the device responsible for a given guest physical address.
    public func findDevice(at address: UInt64) -> (device: any MMIODevice, offset: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        for region in regions {
            if region.contains(address: address) {
                return (region.device, address - region.baseAddress)
            }
        }
        return nil
    }

    /// Dispatch an MMIO read to the correct device.
    /// - Returns: The value read, or 0 if no device is mapped at that address.
    public func read(at address: UInt64, size: Int) -> UInt64 {
        guard let (device, offset) = findDevice(at: address) else {
            // No device mapped. Return all-ones (bus error / RAZ behavior).
            return size == 8 ? UInt64.max : (1 << (size * 8)) - 1
        }
        return device.mmioRead(offset: offset, size: size)
    }

    /// Dispatch an MMIO write to the correct device.
    public func write(at address: UInt64, size: Int, value: UInt64) {
        guard let (device, offset) = findDevice(at: address) else {
            // Write-ignore for unmapped addresses.
            return
        }
        device.mmioWrite(offset: offset, size: size, value: value)
    }

    // MARK: - Private

    private func regionsOverlap(_ a: MMIORegion, _ b: MMIORegion) -> Bool {
        a.baseAddress < b.endAddress && b.baseAddress < a.endAddress
    }
}

// MARK: - Errors

public enum AddressSpaceError: Error, CustomStringConvertible {
    case regionOverlap(existingBase: UInt64, newBase: UInt64)

    public var description: String {
        switch self {
        case .regionOverlap(let existing, let new):
            return "MMIO region overlap: existing 0x\(String(existing, radix: 16)), new 0x\(String(new, radix: 16))"
        }
    }
}
