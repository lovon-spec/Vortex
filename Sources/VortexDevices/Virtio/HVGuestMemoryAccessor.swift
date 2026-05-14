// HVGuestMemoryAccessor.swift -- Virtqueue memory accessor for Hypervisor RAM.
// VortexDevices

import Foundation
import VortexHV

/// Guest memory accessor backed by VortexHV's mapped RAM.
public final class HVGuestMemoryAccessor: GuestMemoryAccessor, @unchecked Sendable {
    private let memoryManager: MemoryManager

    public init(memoryManager: MemoryManager) {
        self.memoryManager = memoryManager
    }

    public func read(at gpa: UInt64, size: Int) -> Data {
        guard size > 0, let ptr = memoryManager.hostPointer(for: gpa) else {
            return Data(count: max(size, 0))
        }
        return Data(bytes: ptr, count: size)
    }

    public func write(at gpa: UInt64, data: Data) {
        guard !data.isEmpty, let ptr = memoryManager.hostPointer(for: gpa) else {
            return
        }
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            ptr.copyMemory(from: base, byteCount: data.count)
        }
    }
}

