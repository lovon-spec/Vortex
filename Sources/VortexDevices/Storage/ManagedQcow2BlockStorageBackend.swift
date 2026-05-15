// ManagedQcow2BlockStorageBackend.swift -- qcow2 backend via managed QEMU NBD.
// VortexDevices

import Darwin
import Foundation

/// qcow2 block backend that delegates qcow2 metadata handling to QEMU's block
/// layer and consumes it through the standard NBD protocol.
///
/// Vortex still owns the guest-visible device model. QEMU is used only as a
/// disk-format engine for formats whose correctness requirements are too high
/// to reimplement casually.
public final class ManagedQcow2BlockStorageBackend: BlockStorageBackend, @unchecked Sendable {
    public var capacityBytes: UInt64 { nbd.capacityBytes }
    public var isReadOnly: Bool { readOnly || nbd.isReadOnly }

    private let server: QEMUNBDServer
    private let nbd: NBDClientBlockStorageBackend
    private let readOnly: Bool

    public init(
        imagePath: String,
        readOnly: Bool = false,
        qemuNBDPath: String? = nil
    ) throws {
        self.readOnly = readOnly
        let server = try QEMUNBDServer(
            imagePath: imagePath,
            format: "qcow2",
            readOnly: readOnly,
            qemuNBDPath: qemuNBDPath
        )
        try server.start()
        do {
            self.nbd = try server.connect()
            self.server = server
        } catch {
            server.stop()
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
        server.stop()
    }

    deinit {
        close()
    }
}

/// Managed qemu-nbd process.
public final class QEMUNBDServer: @unchecked Sendable {
    public let imagePath: String
    public let format: String
    public let readOnly: Bool
    public let qemuNBDPath: String
    public let port: UInt16
    public let exportName: String

    private let process = Process()
    private let stderrPipe = Pipe()
    private var started = false
    private let lock = NSLock()

    public init(
        imagePath: String,
        format: String,
        readOnly: Bool,
        qemuNBDPath: String? = nil,
        exportName: String = "vortex"
    ) throws {
        self.imagePath = imagePath
        self.format = format
        self.readOnly = readOnly
        self.qemuNBDPath = try qemuNBDPath ?? Self.findQEMUNBD()
        self.port = try Self.allocateLocalPort()
        self.exportName = exportName
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        process.executableURL = URL(fileURLWithPath: qemuNBDPath)
        process.arguments = Self.qemuNBDArguments(
            format: format,
            port: port,
            exportName: exportName,
            readOnly: readOnly,
            imagePath: imagePath
        )
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw BlockStorageError.processFailed("Failed to launch \(qemuNBDPath): \(error.localizedDescription)")
        }

        started = true
    }

    public func connect(timeout: TimeInterval = 5.0) throws -> NBDClientBlockStorageBackend {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                return try NBDClientBlockStorageBackend(port: port, exportName: exportName)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let stderr = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        if !stderr.isEmpty {
            throw BlockStorageError.processFailed(stderr)
        }
        throw lastError ?? BlockStorageError.processFailed("Timed out waiting for qemu-nbd on port \(port).")
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

    internal static func qemuNBDArguments(
        format: String,
        port: UInt16,
        exportName: String,
        readOnly: Bool,
        imagePath: String
    ) -> [String] {
        var args = [
            "-f", format,
            "--bind=127.0.0.1",
            "-p", String(port),
            "-x", exportName,
        ]
        if readOnly {
            args.append("-r")
        }
        args.append(imagePath)
        return args
    }

    // MARK: - Discovery

    private static func findQEMUNBD() throws -> String {
        let fileManager = FileManager.default
        let envPath = ProcessInfo.processInfo.environment["VORTEX_QEMU_NBD"]
        let candidates = [
            envPath,
            "/opt/homebrew/bin/qemu-nbd",
            "/usr/local/bin/qemu-nbd",
            "/Applications/UTM.app/Contents/MacOS/qemu-nbd",
            "/Applications/UTM.app/Contents/Resources/qemu/qemu-nbd",
        ].compactMap { $0 }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let utmResources = "/Applications/UTM.app/Contents/Resources"
        if let enumerator = fileManager.enumerator(atPath: utmResources) {
            for case let relativePath as String in enumerator {
                guard (relativePath as NSString).lastPathComponent == "qemu-nbd" else { continue }
                let candidate = (utmResources as NSString).appendingPathComponent(relativePath)
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        throw BlockStorageError.executableNotFound("qemu-nbd")
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
