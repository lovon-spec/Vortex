// VortexServiceControl.swift -- Local control plane for the VM owner service.
// VortexService

import Darwin
import Foundation
import VortexCore

public struct VortexServiceCommand: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case activate
        case openVM
        case stopVM
    }

    public var kind: Kind
    public var vmID: UUID?
    public var startOptions: VortexVMStartOptions?

    public init(kind: Kind, vmID: UUID? = nil, startOptions: VortexVMStartOptions? = nil) {
        self.kind = kind
        self.vmID = vmID
        self.startOptions = startOptions
    }

    public static func launchCommand(arguments: [String]) -> VortexServiceCommand {
        if arguments.count > 1, let id = UUID(uuidString: arguments[1]) {
            return VortexServiceCommand(kind: .openVM, vmID: id)
        }
        return VortexServiceCommand(kind: .activate)
    }
}

public struct VortexVMStartOptions: Codable, Sendable, Equatable {
    public var audioOverride: VortexAudioOverride?

    public init(audioOverride: VortexAudioOverride? = nil) {
        self.audioOverride = audioOverride
    }

    public var hasOverrides: Bool {
        audioOverride != nil
    }
}

public struct VortexAudioOverride: Codable, Sendable, Equatable {
    public var disableAudio: Bool
    public var outputDeviceName: String?
    public var inputDeviceName: String?

    public init(
        disableAudio: Bool = false,
        outputDeviceName: String? = nil,
        inputDeviceName: String? = nil
    ) {
        self.disableAudio = disableAudio
        self.outputDeviceName = outputDeviceName
        self.inputDeviceName = inputDeviceName
    }
}

public final class VortexServiceControlServer {
    private static let maxMessageBytes = 64 * 1024
    private static let okResponse = Data("ok\n".utf8)
    private static let errorResponse = Data("error\n".utf8)

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.vortex.service.control-socket")

    public init() {}

    @discardableResult
    public func start(handler: @escaping @MainActor (VortexServiceCommand) -> Void) -> Bool {
        guard source == nil else { return true }

        do {
            try FileManager.default.createDirectory(
                at: Self.socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            VortexLog.service.error("Failed to create control socket directory: \(error.localizedDescription)")
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            VortexLog.service.error("Failed to create control socket: errno \(errno)")
            return false
        }

        Self.disableSIGPIPE(fd)
        _ = Self.setNonBlocking(fd)

        var address = sockaddr_un()
        guard Self.configure(&address, path: Self.socketURL.path) else {
            close(fd)
            VortexLog.service.error("Control socket path is too long: \(Self.socketURL.path)")
            return false
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            VortexLog.service.error("Failed to bind control socket: errno \(err)")
            return false
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            VortexLog.service.error("Failed to listen on control socket: errno \(err)")
            return false
        }

        listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.acceptConnections(handler: handler)
        }
        readSource.setCancelHandler {
            close(fd)
        }
        source = readSource
        readSource.resume()
        VortexLog.service.info("Control socket listening at \(Self.socketURL.path)")
        return true
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            listenFD = -1
        }
        unlink(Self.socketURL.path)
    }

    deinit {
        stop()
    }

    private func acceptConnections(handler: @escaping @MainActor (VortexServiceCommand) -> Void) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                VortexLog.service.error("Control socket accept failed: errno \(errno)")
                return
            }
            Self.disableSIGPIPE(clientFD)
            _ = Self.setBlocking(clientFD)
            Self.setReceiveTimeout(clientFD, seconds: 2)
            handleClient(clientFD, handler: handler)
        }
    }

    private func handleClient(
        _ clientFD: Int32,
        handler: @escaping @MainActor (VortexServiceCommand) -> Void
    ) {
        defer { close(clientFD) }

        do {
            let data = try Self.readFramedMessage(from: clientFD)
            let command = try JSONDecoder().decode(VortexServiceCommand.self, from: data)
            Task { @MainActor in
                handler(command)
            }
            try Self.writeAll(Self.okResponse, to: clientFD)
        } catch {
            VortexLog.service.error("Failed to decode control command: \(error.localizedDescription)")
            try? Self.writeAll(Self.errorResponse, to: clientFD)
        }
    }
}

public enum VortexServiceControlClient {
    @discardableResult
    public static func forwardToRunningService(_ command: VortexServiceCommand) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        VortexServiceControlServer.disableSIGPIPE(fd)
        VortexServiceControlServer.setReceiveTimeout(fd, seconds: 2)

        var address = sockaddr_un()
        guard VortexServiceControlServer.configure(
            &address,
            path: VortexServiceControlServer.socketURL.path
        ) else {
            return false
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            if errno == ECONNREFUSED || errno == ENOENT {
                unlink(VortexServiceControlServer.socketURL.path)
            }
            return false
        }

        guard let data = try? JSONEncoder().encode(command) else {
            return false
        }
        do {
            try VortexServiceControlServer.writeFramedMessage(data, to: fd)
        } catch {
            return false
        }

        var response = [UInt8](repeating: 0, count: 16)
        let responseCapacity = response.count
        let responseBytes = response.withUnsafeMutableBytes {
            read(fd, $0.baseAddress, responseCapacity)
        }
        guard responseBytes > 0 else {
            return false
        }
        return Data(response.prefix(responseBytes)) == Data("ok\n".utf8)
    }
}

extension VortexServiceControlServer {
    public static var socketURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Vortex", isDirectory: true)
            .appendingPathComponent("VortexService.sock")
    }

    fileprivate static func configure(_ address: inout sockaddr_un, path: String) -> Bool {
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)

        return withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            guard pathBytes.count <= rawBuffer.count else {
                return false
            }
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = UInt8(bitPattern: byte)
            }
            return true
        }
    }

    fileprivate static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    fileprivate static func setBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0
    }

    fileprivate static func disableSIGPIPE(_ fd: Int32) {
        var value: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    fileprivate static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    fileprivate static func writeFramedMessage(_ data: Data, to fd: Int32) throws {
        guard data.count <= maxMessageBytes else {
            throw VortexServiceControlError.messageTooLarge
        }

        var length = UInt32(data.count).bigEndian
        let lengthData = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(lengthData, to: fd)
        try writeAll(data, to: fd)
    }

    fileprivate static func readFramedMessage(from fd: Int32) throws -> Data {
        let lengthData = try readExactly(byteCount: MemoryLayout<UInt32>.size, from: fd)
        var rawLength: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &rawLength) { buffer in
            lengthData.copyBytes(to: buffer)
        }

        let length = Int(UInt32(bigEndian: rawLength))
        guard length > 0, length <= maxMessageBytes else {
            throw VortexServiceControlError.invalidMessageLength(length)
        }

        return try readExactly(byteCount: length, from: fd)
    }

    fileprivate static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let result = write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                } else {
                    throw VortexServiceControlError.connectionClosed
                }
            }
        }
    }

    fileprivate static func readExactly(byteCount: Int, from fd: Int32) throws -> Data {
        var data = [UInt8](repeating: 0, count: byteCount)
        var offset = 0

        while offset < byteCount {
            let remaining = byteCount - offset
            let result = data.withUnsafeMutableBytes { buffer in
                read(fd, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            if result > 0 {
                offset += result
            } else if result == 0 {
                throw VortexServiceControlError.connectionClosed
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        return Data(data)
    }
}

private enum VortexServiceControlError: LocalizedError {
    case connectionClosed
    case invalidMessageLength(Int)
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "control socket closed before the full message was transferred"
        case .invalidMessageLength(let length):
            return "invalid control message length \(length)"
        case .messageTooLarge:
            return "control message exceeds the maximum supported size"
        }
    }
}
