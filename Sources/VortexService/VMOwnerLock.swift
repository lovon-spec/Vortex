// VMOwnerLock.swift -- Process-held guard for exclusive VM ownership.
// VortexService

import Darwin
import Foundation
import VortexCore
import VortexPersistence

public enum VMOwnerLockError: LocalizedError, Sendable {
    case alreadyOwned(vmID: UUID, lockPath: String, ownerDescription: String)
    case lockFailed(vmID: UUID, lockPath: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyOwned(let vmID, let lockPath, let ownerDescription):
            return """
            VM \(vmID.uuidString) is already owned by another Vortex process.
            Lock: \(lockPath)
            Owner: \(ownerDescription)
            """
        case .lockFailed(let vmID, let lockPath, let errno):
            return "Failed to lock VM \(vmID.uuidString) at \(lockPath): errno \(errno)."
        }
    }
}

/// Holds an advisory process lock for one VM.
///
/// The lock is backed by `flock(2)` and is therefore released automatically if
/// the owning process exits. Keeping this object alive keeps the file descriptor
/// and lock alive.
public final class VMOwnerLock: @unchecked Sendable {
    public let vmID: UUID
    public let lockURL: URL

    private let mutex = NSLock()
    private var fd: Int32

    private init(vmID: UUID, lockURL: URL, fd: Int32) {
        self.vmID = vmID
        self.lockURL = lockURL
        self.fd = fd
    }

    deinit {
        release()
    }

    public static func acquire(
        vmID: UUID,
        fileManager: VMFileManager = VMFileManager()
    ) throws -> VMOwnerLock {
        let lockDirectory = fileManager.baseDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )

        let lockURL = lockDirectory.appendingPathComponent("\(vmID.uuidString).lock")
        let fd = open(
            lockURL.path,
            O_RDWR | O_CREAT,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard fd >= 0 else {
            throw VMOwnerLockError.lockFailed(
                vmID: vmID,
                lockPath: lockURL.path,
                errno: errno
            )
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK {
                throw VMOwnerLockError.alreadyOwned(
                    vmID: vmID,
                    lockPath: lockURL.path,
                    ownerDescription: ownerDescription(at: lockURL)
                )
            }
            throw VMOwnerLockError.lockFailed(
                vmID: vmID,
                lockPath: lockURL.path,
                errno: err
            )
        }

        let lock = VMOwnerLock(vmID: vmID, lockURL: lockURL, fd: fd)
        lock.writeOwnerMetadata()
        VortexLog.service.info("Acquired VM owner lock for \(vmID.uuidString)")
        return lock
    }

    public func release() {
        mutex.lock()
        defer { mutex.unlock() }

        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        VortexLog.service.info("Released VM owner lock for \(self.vmID.uuidString)")
    }

    private func writeOwnerMetadata() {
        let metadata = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        process=\(ProcessInfo.processInfo.processName)
        acquiredAt=\(ISO8601DateFormatter().string(from: Date()))
        arguments=\(ProcessInfo.processInfo.arguments.joined(separator: " "))
        """

        guard let data = metadata.data(using: .utf8) else { return }
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        _ = data.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, data.count)
        }
        fsync(fd)
    }

    private static func ownerDescription(at lockURL: URL) -> String {
        guard let data = try? Data(contentsOf: lockURL),
              let text = String(data: data, encoding: .utf8) else {
            return "unknown Vortex process"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown Vortex process" : trimmed
    }
}
