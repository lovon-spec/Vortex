// BlockStorageBackend.swift -- Host block storage abstractions.
// VortexDevices

import Foundation

/// Sector size exposed by Vortex block devices.
public let vortexBlockSectorSize: UInt64 = 512

/// Host-side block storage implementation.
public protocol BlockStorageBackend: AnyObject, Sendable {
    /// Logical device capacity in bytes.
    var capacityBytes: UInt64 { get }

    /// Whether write requests are rejected.
    var isReadOnly: Bool { get }

    /// Read exactly `length` bytes at `offset`.
    func read(offset: UInt64, length: Int) throws -> Data

    /// Write `data` at `offset`.
    func write(offset: UInt64, data: Data) throws

    /// Flush durable state.
    func flush() throws

    /// Close the backend and release resources.
    func close()
}

/// Errors raised by block storage backends.
public enum BlockStorageError: Error, CustomStringConvertible {
    case readOnly
    case outOfBounds(offset: UInt64, length: UInt64, capacity: UInt64)
    case shortRead(expected: Int, actual: Int)
    case shortWrite(expected: Int, actual: Int)
    case openFailed(path: String, errno: Int32)
    case ioFailed(operation: String, errno: Int32)
    case invalidResponse(String)
    case executableNotFound(String)
    case processFailed(String)

    public var description: String {
        switch self {
        case .readOnly:
            return "Block device is read-only."
        case .outOfBounds(let offset, let length, let capacity):
            return "Block access out of bounds: offset=\(offset), length=\(length), capacity=\(capacity)."
        case .shortRead(let expected, let actual):
            return "Short block read: expected \(expected) bytes, got \(actual)."
        case .shortWrite(let expected, let actual):
            return "Short block write: expected \(expected) bytes, wrote \(actual)."
        case .openFailed(let path, let err):
            return "Failed to open \(path): errno \(err)."
        case .ioFailed(let operation, let err):
            return "\(operation) failed: errno \(err)."
        case .invalidResponse(let reason):
            return "Invalid block backend response: \(reason)."
        case .executableNotFound(let name):
            return "Required executable not found: \(name)."
        case .processFailed(let reason):
            return "Block backend process failed: \(reason)."
        }
    }
}

extension BlockStorageBackend {
    func validateRange(offset: UInt64, length: UInt64) throws {
        guard offset <= capacityBytes, length <= capacityBytes - offset else {
            throw BlockStorageError.outOfBounds(
                offset: offset,
                length: length,
                capacity: capacityBytes
            )
        }
    }
}

