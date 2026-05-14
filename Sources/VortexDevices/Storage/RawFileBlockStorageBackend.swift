// RawFileBlockStorageBackend.swift -- RAW disk image block backend.
// VortexDevices

import Darwin
import Foundation

/// Block backend backed by a plain RAW file.
public final class RawFileBlockStorageBackend: BlockStorageBackend, @unchecked Sendable {
    public let capacityBytes: UInt64
    public let isReadOnly: Bool

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    public init(path: String, readOnly: Bool = false) throws {
        self.isReadOnly = readOnly

        let flags = readOnly ? O_RDONLY : O_RDWR
        let descriptor = open(path, flags)
        guard descriptor >= 0 else {
            throw BlockStorageError.openFailed(path: path, errno: errno)
        }
        self.fd = descriptor

        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0 else {
            let err = errno
            Darwin.close(descriptor)
            throw BlockStorageError.ioFailed(operation: "fstat", errno: err)
        }

        self.capacityBytes = UInt64(statBuffer.st_size)
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        try validateRange(offset: offset, length: UInt64(length))
        guard length > 0 else { return Data() }

        var data = Data(count: length)
        let bytesRead: Int = data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return -1 }
            lock.lock()
            let result = pread(fd, base, length, off_t(offset))
            lock.unlock()
            return result
        }

        guard bytesRead >= 0 else {
            throw BlockStorageError.ioFailed(operation: "pread", errno: errno)
        }
        guard bytesRead == length else {
            throw BlockStorageError.shortRead(expected: length, actual: bytesRead)
        }
        return data
    }

    public func write(offset: UInt64, data: Data) throws {
        guard !isReadOnly else { throw BlockStorageError.readOnly }
        try validateRange(offset: offset, length: UInt64(data.count))
        guard !data.isEmpty else { return }

        let bytesWritten: Int = data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return -1 }
            lock.lock()
            let result = pwrite(fd, base, data.count, off_t(offset))
            lock.unlock()
            return result
        }

        guard bytesWritten >= 0 else {
            throw BlockStorageError.ioFailed(operation: "pwrite", errno: errno)
        }
        guard bytesWritten == data.count else {
            throw BlockStorageError.shortWrite(expected: data.count, actual: bytesWritten)
        }
    }

    public func flush() throws {
        lock.lock()
        let result = fsync(fd)
        lock.unlock()
        guard result == 0 else {
            throw BlockStorageError.ioFailed(operation: "fsync", errno: errno)
        }
    }

    public func close() {
        lock.lock()
        if !closed {
            Darwin.close(fd)
            closed = true
        }
        lock.unlock()
    }

    deinit {
        close()
    }
}
