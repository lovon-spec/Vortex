// NBDClientBlockStorageBackend.swift -- Network Block Device client backend.
// VortexDevices

import Darwin
import Foundation

/// Synchronous NBD client block backend.
///
/// This backend intentionally speaks the standard NBD protocol directly instead
/// of asking Virtualization.framework to attach storage. It lets the native HV
/// backend consume any source that can be exported as a block device, including
/// qcow2 through QEMU's block layer.
public final class NBDClientBlockStorageBackend: BlockStorageBackend, @unchecked Sendable {
    public private(set) var capacityBytes: UInt64 = 0
    public private(set) var isReadOnly: Bool = false
    public private(set) var supportsFlush: Bool = false

    private let socketFD: Int32
    private let lock = NSLock()
    private var nextHandle: UInt64 = 1
    private var closed = false

    public init(host: String = "127.0.0.1", port: UInt16, exportName: String = "") throws {
        socketFD = try Self.connect(host: host, port: port)
        try negotiate(exportName: exportName)
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        try validateRange(offset: offset, length: UInt64(length))
        guard length > 0 else { return Data() }

        lock.lock()
        defer { lock.unlock() }

        let handle = nextRequestHandle()
        try sendRequest(type: .read, handle: handle, offset: offset, length: UInt32(length))
        let reply = try readReply(expectedHandle: handle)
        guard reply.error == 0 else {
            throw BlockStorageError.invalidResponse("NBD read failed with error \(reply.error).")
        }
        return try readExact(length)
    }

    public func write(offset: UInt64, data: Data) throws {
        guard !isReadOnly else { throw BlockStorageError.readOnly }
        try validateRange(offset: offset, length: UInt64(data.count))
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        let handle = nextRequestHandle()
        try sendRequest(type: .write, handle: handle, offset: offset, length: UInt32(data.count))
        try writeAll(data)
        let reply = try readReply(expectedHandle: handle)
        guard reply.error == 0 else {
            throw BlockStorageError.invalidResponse("NBD write failed with error \(reply.error).")
        }
    }

    public func flush() throws {
        guard supportsFlush else { return }

        lock.lock()
        defer { lock.unlock() }

        let handle = nextRequestHandle()
        try sendRequest(type: .flush, handle: handle, offset: 0, length: 0)
        let reply = try readReply(expectedHandle: handle)
        guard reply.error == 0 else {
            throw BlockStorageError.invalidResponse("NBD flush failed with error \(reply.error).")
        }
    }

    public func close() {
        lock.lock()
        if !closed {
            try? sendRequest(type: .disconnect, handle: nextRequestHandle(), offset: 0, length: 0)
            Darwin.close(socketFD)
            closed = true
        }
        lock.unlock()
    }

    deinit {
        close()
    }

    // MARK: - Negotiation

    private func negotiate(exportName: String) throws {
        let oldStyleMagic = try readUInt64BE()
        guard oldStyleMagic == 0x4e42_444d_4147_4943 else {
            throw BlockStorageError.invalidResponse("Missing NBDMAGIC.")
        }

        let optionsMagic = try readUInt64BE()
        guard optionsMagic == 0x4948_4156_454f_5054 else {
            throw BlockStorageError.invalidResponse("Missing IHAVEOPT.")
        }

        _ = try readUInt16BE() // handshake flags
        try writeUInt32BE(0)   // client flags

        let exportData = Data(exportName.utf8)
        try writeUInt64BE(0x4948_4156_454f_5054)
        try writeUInt32BE(1) // NBD_OPT_EXPORT_NAME
        try writeUInt32BE(UInt32(exportData.count))
        try writeAll(exportData)

        capacityBytes = try readUInt64BE()
        let transmissionFlags = try readUInt16BE()
        isReadOnly = (transmissionFlags & 0x0002) != 0
        supportsFlush = (transmissionFlags & 0x0004) != 0
        _ = try readExact(124) // reserved
    }

    // MARK: - Requests

    private enum RequestType: UInt16 {
        case read = 0
        case write = 1
        case disconnect = 2
        case flush = 3
    }

    private struct Reply {
        let error: UInt32
        let handle: UInt64
    }

    private func nextRequestHandle() -> UInt64 {
        let handle = nextHandle
        nextHandle &+= 1
        return handle
    }

    private func sendRequest(
        type: RequestType,
        handle: UInt64,
        offset: UInt64,
        length: UInt32
    ) throws {
        var data = Data()
        data.appendBE(UInt32(0x2560_9513)) // NBD_REQUEST_MAGIC
        data.appendBE(UInt16(0))           // flags
        data.appendBE(type.rawValue)
        data.appendBE(handle)
        data.appendBE(offset)
        data.appendBE(length)
        try writeAll(data)
    }

    private func readReply(expectedHandle: UInt64) throws -> Reply {
        let magic = try readUInt32BE()
        guard magic == 0x6744_6698 else {
            throw BlockStorageError.invalidResponse("Bad NBD reply magic 0x\(String(magic, radix: 16)).")
        }
        let error = try readUInt32BE()
        let handle = try readUInt64BE()
        guard handle == expectedHandle else {
            throw BlockStorageError.invalidResponse("Unexpected NBD handle \(handle), expected \(expectedHandle).")
        }
        return Reply(error: error, handle: handle)
    }

    // MARK: - Socket I/O

    private static func connect(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw BlockStorageError.invalidResponse("getaddrinfo failed for \(host):\(port).")
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return fd
                }
                Darwin.close(fd)
            }
            cursor = info.pointee.ai_next
        }

        throw BlockStorageError.ioFailed(operation: "connect", errno: errno)
    }

    private func readExact(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let n: Int = data.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.recv(socketFD, base.advanced(by: received), count - received, 0)
            }
            guard n > 0 else {
                throw BlockStorageError.ioFailed(operation: "recv", errno: n == 0 ? ECONNRESET : errno)
            }
            received += n
        }
        return data
    }

    private func writeAll(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while sent < data.count {
                let n = Darwin.send(socketFD, base.advanced(by: sent), data.count - sent, 0)
                guard n >= 0 else {
                    throw BlockStorageError.ioFailed(operation: "send", errno: errno)
                }
                sent += n
            }
        }
    }

    private func readUInt16BE() throws -> UInt16 {
        try readExact(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
    }

    private func readUInt32BE() throws -> UInt32 {
        try readExact(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }

    private func readUInt64BE() throws -> UInt64 {
        try readExact(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }

    private func writeUInt32BE(_ value: UInt32) throws {
        var be = value.bigEndian
        try Swift.withUnsafeBytes(of: &be) { try writeAll(Data($0)) }
    }

    private func writeUInt64BE(_ value: UInt64) throws {
        var be = value.bigEndian
        try Swift.withUnsafeBytes(of: &be) { try writeAll(Data($0)) }
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt64) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
