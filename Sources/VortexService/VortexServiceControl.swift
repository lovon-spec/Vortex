// VortexServiceControl.swift -- Local control plane for the VM owner service.
// VortexService

import Darwin
import Foundation
import VortexCore

public struct VortexServiceCommand: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case activate
        case openVM
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
            handleClient(clientFD, handler: handler)
        }
    }

    private func handleClient(
        _ clientFD: Int32,
        handler: @escaping @MainActor (VortexServiceCommand) -> Void
    ) {
        defer { close(clientFD) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bufferCapacity = buffer.count
        let count = buffer.withUnsafeMutableBytes {
            read(clientFD, $0.baseAddress, bufferCapacity)
        }
        guard count > 0 else { return }

        let data = Data(buffer.prefix(count))
        do {
            let command = try JSONDecoder().decode(VortexServiceCommand.self, from: data)
            Task { @MainActor in
                handler(command)
            }
            _ = "ok\n".withCString {
                write(clientFD, $0, strlen($0))
            }
        } catch {
            VortexLog.service.error("Failed to decode control command: \(error.localizedDescription)")
            _ = "error\n".withCString {
                write(clientFD, $0, strlen($0))
            }
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
        let bytesWritten = data.withUnsafeBytes {
            write(fd, $0.baseAddress, data.count)
        }
        guard bytesWritten == data.count else {
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
}
