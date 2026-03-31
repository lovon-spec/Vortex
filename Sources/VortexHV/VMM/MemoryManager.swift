// MemoryManager.swift -- Guest physical address memory management.
// VortexHV

import Foundation
import Hypervisor

// MARK: - Mapped Region

/// Tracks a single region of host memory mapped into the guest physical address space.
public struct MappedRegion: @unchecked Sendable {
    /// Host virtual address of the mapping.
    public let hostPointer: UnsafeMutableRawPointer
    /// Guest physical address.
    public let guestAddress: UInt64
    /// Size in bytes.
    public let size: UInt64
    /// Whether this region was allocated by us (and should be munmapped on cleanup).
    public let ownsMemory: Bool
}

// MARK: - Memory Manager

/// Manages allocation and mapping of host memory into the guest physical address space
/// via Hypervisor.framework.
public final class MemoryManager: @unchecked Sendable {
    private let lock = NSLock()
    private var regions: [MappedRegion] = []

    public init() {}

    /// Allocate host memory and map it into the guest as read/write/execute RAM.
    ///
    /// - Parameters:
    ///   - gpa: Page-aligned guest physical address.
    ///   - size: Size in bytes (will be page-aligned up).
    /// - Returns: Host pointer to the mapped memory.
    @discardableResult
    public func mapRAM(at gpa: UInt64, size: UInt64) throws -> UnsafeMutableRawPointer {
        let alignedSize = pageAlignUp(size)

        // Allocate host memory. Use mmap for page-aligned anonymous memory.
        let ptr = mmap(
            nil,
            Int(alignedSize),
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS,
            -1, // fd
            0   // offset
        )
        guard let hostPtr = ptr, hostPtr != MAP_FAILED else {
            throw MemoryManagerError.allocationFailed(size: alignedSize)
        }

        // Map into guest physical address space with RWX permissions.
        let flags: hv_memory_flags_t = UInt64(HV_MEMORY_READ) | UInt64(HV_MEMORY_WRITE) | UInt64(HV_MEMORY_EXEC)
        let ret = hv_vm_map(hostPtr, gpa, Int(alignedSize), flags)
        guard ret == HV_SUCCESS else {
            munmap(hostPtr, Int(alignedSize))
            throw MemoryManagerError.hvMapFailed(gpa: gpa, code: ret)
        }

        let region = MappedRegion(
            hostPointer: hostPtr,
            guestAddress: gpa,
            size: alignedSize,
            ownsMemory: true
        )
        lock.lock()
        regions.append(region)
        lock.unlock()

        return hostPtr
    }

    /// Map existing data (firmware, DTB) into the guest as read-only ROM.
    ///
    /// - Parameters:
    ///   - gpa: Page-aligned guest physical address.
    ///   - data: The data to map. A copy is made into a page-aligned buffer.
    /// - Returns: Host pointer to the mapped memory.
    @discardableResult
    public func mapROM(at gpa: UInt64, data: Data) throws -> UnsafeMutableRawPointer {
        let alignedSize = pageAlignUp(UInt64(data.count))

        let ptr = mmap(
            nil,
            Int(alignedSize),
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS,
            -1,
            0
        )
        guard let hostPtr = ptr, hostPtr != MAP_FAILED else {
            throw MemoryManagerError.allocationFailed(size: alignedSize)
        }

        // Copy data into the page-aligned buffer.
        data.withUnsafeBytes { src in
            hostPtr.copyMemory(from: src.baseAddress!, byteCount: data.count)
        }

        // Map as read-only + executable (firmware may contain code).
        let flags: hv_memory_flags_t = UInt64(HV_MEMORY_READ) | UInt64(HV_MEMORY_EXEC)
        let ret = hv_vm_map(hostPtr, gpa, Int(alignedSize), flags)
        guard ret == HV_SUCCESS else {
            munmap(hostPtr, Int(alignedSize))
            throw MemoryManagerError.hvMapFailed(gpa: gpa, code: ret)
        }

        let region = MappedRegion(
            hostPointer: hostPtr,
            guestAddress: gpa,
            size: alignedSize,
            ownsMemory: true
        )
        lock.lock()
        regions.append(region)
        lock.unlock()

        return hostPtr
    }

    /// Map caller-owned memory into the guest. The caller is responsible for the host memory lifetime.
    public func mapExternal(
        hostPointer: UnsafeMutableRawPointer,
        at gpa: UInt64,
        size: UInt64,
        flags: hv_memory_flags_t
    ) throws {
        let alignedSize = pageAlignUp(size)
        let ret = hv_vm_map(hostPointer, gpa, Int(alignedSize), flags)
        guard ret == HV_SUCCESS else {
            throw MemoryManagerError.hvMapFailed(gpa: gpa, code: ret)
        }
        let region = MappedRegion(
            hostPointer: hostPointer,
            guestAddress: gpa,
            size: alignedSize,
            ownsMemory: false
        )
        lock.lock()
        regions.append(region)
        lock.unlock()
    }

    /// Unmap a single region from the guest.
    public func unmap(at gpa: UInt64, size: UInt64) {
        let alignedSize = pageAlignUp(size)
        _ = hv_vm_unmap(gpa, Int(alignedSize))

        lock.lock()
        if let index = regions.firstIndex(where: { $0.guestAddress == gpa }) {
            let region = regions.remove(at: index)
            lock.unlock()
            if region.ownsMemory {
                munmap(region.hostPointer, Int(region.size))
            }
        } else {
            lock.unlock()
        }
    }

    /// Look up the host pointer for a guest physical address.
    public func hostPointer(for gpa: UInt64) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        for region in regions {
            let regionEnd = region.guestAddress &+ region.size
            if gpa >= region.guestAddress && gpa < regionEnd {
                let offset = Int(gpa - region.guestAddress)
                return region.hostPointer.advanced(by: offset)
            }
        }
        return nil
    }

    /// Unmap all regions and free owned memory.
    public func cleanup() {
        lock.lock()
        let allRegions = regions
        regions.removeAll()
        lock.unlock()

        for region in allRegions {
            _ = hv_vm_unmap(region.guestAddress, Int(region.size))
            if region.ownsMemory {
                munmap(region.hostPointer, Int(region.size))
            }
        }
    }

    deinit {
        cleanup()
    }
}

// MARK: - Errors

public enum MemoryManagerError: Error, CustomStringConvertible {
    case allocationFailed(size: UInt64)
    case hvMapFailed(gpa: UInt64, code: hv_return_t)

    public var description: String {
        switch self {
        case .allocationFailed(let size):
            return "Failed to allocate \(size) bytes of host memory"
        case .hvMapFailed(let gpa, let code):
            return "hv_vm_map failed at GPA 0x\(String(gpa, radix: 16)) with error \(code)"
        }
    }
}
