// SSHManagedQcow2BlockStorageBackend.swift -- Remote qcow2 backend via SSH-managed QEMU NBD.
// VortexDevices

import Darwin
import Foundation

/// qcow2 block backend for images reachable through SSH.
///
/// The remote host runs `qemu-nbd` against the qcow2 image and SSH forwards the
/// NBD export back to a local loopback port. Vortex still owns the guest-visible
/// virtio block device; QEMU is only the qcow2 block-format engine.
public final class SSHManagedQcow2BlockStorageBackend: BlockStorageBackend, @unchecked Sendable {
    public var capacityBytes: UInt64 { nbd.capacityBytes }
    public var isReadOnly: Bool { readOnly || nbd.isReadOnly }

    private let tunnel: SSHQEMUNBDTunnel
    private let nbd: NBDClientBlockStorageBackend
    private let readOnly: Bool

    public init(imageURLString: String, readOnly: Bool = false) throws {
        let resource = try SSHResource(urlString: imageURLString)
        self.readOnly = readOnly

        let tunnel = try SSHQEMUNBDTunnel(resource: resource, readOnly: readOnly)
        try tunnel.start()
        do {
            self.nbd = try tunnel.connect()
            self.tunnel = tunnel
        } catch {
            tunnel.stop()
            throw error
        }
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        try nbd.read(offset: offset, length: length)
    }

    public func write(offset: UInt64, data: Data) throws {
        guard !readOnly else { throw BlockStorageError.readOnly }
        try nbd.write(offset: offset, data: data)
    }

    public func flush() throws {
        try nbd.flush()
    }

    public func close() {
        nbd.close()
        tunnel.stop()
    }

    deinit {
        close()
    }
}

/// Parsed `ssh://user@host[:port]/absolute/path` resource.
public struct SSHResource: Sendable, Hashable {
    public let user: String?
    public let host: String
    public let port: Int?
    public let path: String

    public init(urlString: String) throws {
        guard let components = URLComponents(string: urlString),
              components.scheme == "ssh",
              let host = components.host,
              !components.path.isEmpty else {
            throw BlockStorageError.invalidResponse("Expected ssh://user@host/path, got \(urlString).")
        }
        self.user = components.user
        self.host = host
        self.port = components.port
        self.path = components.percentEncodedPath.removingPercentEncoding ?? components.path
    }

    public var destination: String {
        if let user, !user.isEmpty {
            return "\(user)@\(host)"
        }
        return host
    }
}

public final class SSHQEMUNBDTunnel: @unchecked Sendable {
    public let resource: SSHResource
    public let localPort: UInt16
    public let remotePort: UInt16
    public let exportName: String
    public let readOnly: Bool

    private let process = Process()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var started = false

    public init(
        resource: SSHResource,
        readOnly: Bool,
        exportName: String = "vortex"
    ) throws {
        self.resource = resource
        self.readOnly = readOnly
        self.exportName = exportName
        self.localPort = try Self.allocateLocalPort()
        self.remotePort = UInt16.random(in: 20000...60999)
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
        ]
        if let port = resource.port {
            args.append(contentsOf: ["-p", String(port)])
        }
        args.append(resource.destination)
        args.append(remoteCommand())

        process.arguments = args
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw BlockStorageError.processFailed("Failed to launch ssh for \(resource.destination): \(error.localizedDescription)")
        }

        started = true
    }

    public func connect(timeout: TimeInterval = 10.0) throws -> NBDClientBlockStorageBackend {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                return try NBDClientBlockStorageBackend(port: localPort, exportName: exportName)
            } catch {
                lastError = error
                if !process.isRunning {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let stderr = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        if !stderr.isEmpty {
            throw BlockStorageError.processFailed(stderr)
        }
        throw lastError ?? BlockStorageError.processFailed("Timed out waiting for remote qemu-nbd on \(resource.destination).")
    }

    public func stop() {
        lock.lock()
        if started && process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        started = false
        lock.unlock()
    }

    deinit {
        stop()
    }

    private func remoteCommand() -> String {
        let qemuArgs = Self.qemuNBDArguments(
            remotePort: remotePort,
            exportName: exportName,
            readOnly: readOnly,
            imagePath: resource.path
        )
        let argv = qemuArgs.map(Self.shellQuote).joined(separator: " ")
        return """
        q="${VORTEX_QEMU_NBD:-}"; \
        if [ -z "$q" ]; then for p in /opt/homebrew/bin/qemu-nbd /usr/local/bin/qemu-nbd /Applications/UTM.app/Contents/Resources/qemu/qemu-nbd; do [ -x "$p" ] && q="$p" && break; done; fi; \
        if [ -z "$q" ]; then echo "qemu-nbd not found" >&2; exit 127; fi; \
        exec "$q" \(argv)
        """
    }

    internal static func qemuNBDArguments(
        remotePort: UInt16,
        exportName: String,
        readOnly: Bool,
        imagePath: String
    ) -> [String] {
        var args = [
            "-f", "qcow2",
            "--bind=127.0.0.1",
            "-p", String(remotePort),
            "-x", exportName,
        ]
        if readOnly {
            args.append("-r")
        }
        args.append(imagePath)
        return args
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func allocateLocalPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BlockStorageError.ioFailed(operation: "socket", errno: errno)
        }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw BlockStorageError.ioFailed(operation: "bind", errno: errno)
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            throw BlockStorageError.ioFailed(operation: "getsockname", errno: errno)
        }

        return UInt16(bigEndian: addr.sin_port)
    }
}
