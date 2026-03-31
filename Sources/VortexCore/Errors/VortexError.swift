// VortexError.swift — Comprehensive error types for the Vortex VM manager.
// VortexCore

import Foundation

/// Errors that can occur throughout the Vortex VM management stack.
public enum VortexError: Error, Sendable {

    // MARK: - VM lifecycle

    /// The requested VM was not found.
    case vmNotFound(id: UUID)

    /// The requested state transition is invalid from the current state.
    case invalidStateTransition(from: VMState, to: VMState)

    /// VM creation failed.
    case vmCreationFailed(reason: String)

    /// The VM failed to start.
    case vmStartFailed(reason: String)

    /// The VM failed to stop within the expected timeout.
    case vmStopTimeout(id: UUID, timeoutSeconds: Int)

    // MARK: - Configuration

    /// The VM configuration is invalid.
    case invalidConfiguration(issues: [String])

    /// A required file (disk image, kernel, firmware) was not found at the expected path.
    case fileNotFound(path: String)

    /// A file already exists where one should be created.
    case fileAlreadyExists(path: String)

    // MARK: - Hardware / resources

    /// The requested hardware resources are not available on this host.
    case insufficientResources(reason: String)

    /// A device configuration or initialization failed.
    case deviceConfigurationFailed(device: String, reason: String)

    /// A device failed to activate after guest driver negotiation.
    case deviceActivationFailed(device: String, reason: String)

    // MARK: - Storage

    /// A disk operation (create, resize, clone) failed.
    case diskOperationFailed(reason: String)

    // MARK: - Network

    /// A network interface could not be configured.
    case networkConfigurationFailed(reason: String)

    // MARK: - Audio

    /// The requested audio device was not found on the host.
    case audioDeviceNotFound(deviceUID: String)

    /// Audio routing could not be applied.
    case audioRoutingFailed(reason: String)

    // MARK: - Snapshots

    /// A snapshot operation (save or restore) failed.
    case snapshotFailed(reason: String)

    // MARK: - Persistence

    /// A persistence (save/load) operation failed.
    case persistenceFailed(reason: String)

    // MARK: - Boot

    /// The boot process failed.
    case bootFailed(reason: String)

    /// The IPSW restore image is invalid or unsupported.
    case invalidRestoreImage(path: String, reason: String)

    // MARK: - General

    /// An internal error that should not normally occur.
    case internalError(reason: String)

    /// An operation is not supported on this platform or configuration.
    case unsupported(feature: String, reason: String)
}

// MARK: - LocalizedError

extension VortexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .vmNotFound(let id):
            return "VM not found: \(id.uuidString)."
        case .invalidStateTransition(let from, let to):
            return "Invalid state transition from '\(from.rawValue)' to '\(to.rawValue)'."
        case .vmCreationFailed(let reason):
            return "VM creation failed: \(reason)"
        case .vmStartFailed(let reason):
            return "VM failed to start: \(reason)"
        case .vmStopTimeout(let id, let timeout):
            return "VM \(id.uuidString) did not stop within \(timeout) seconds."
        case .invalidConfiguration(let issues):
            return "Invalid VM configuration: \(issues.joined(separator: "; "))"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .fileAlreadyExists(let path):
            return "File already exists: \(path)"
        case .insufficientResources(let reason):
            return "Insufficient host resources: \(reason)"
        case .deviceConfigurationFailed(let device, let reason):
            return "Device '\(device)' configuration failed: \(reason)"
        case .deviceActivationFailed(let device, let reason):
            return "Device '\(device)' activation failed: \(reason)"
        case .diskOperationFailed(let reason):
            return "Disk operation failed: \(reason)"
        case .networkConfigurationFailed(let reason):
            return "Network configuration failed: \(reason)"
        case .audioDeviceNotFound(let uid):
            return "Audio device not found: \(uid)"
        case .audioRoutingFailed(let reason):
            return "Audio routing failed: \(reason)"
        case .snapshotFailed(let reason):
            return "Snapshot operation failed: \(reason)"
        case .persistenceFailed(let reason):
            return "Persistence operation failed: \(reason)"
        case .bootFailed(let reason):
            return "Boot failed: \(reason)"
        case .invalidRestoreImage(let path, let reason):
            return "Invalid restore image at \(path): \(reason)"
        case .internalError(let reason):
            return "Internal error: \(reason)"
        case .unsupported(let feature, let reason):
            return "\(feature) is not supported: \(reason)"
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension VortexError: CustomDebugStringConvertible {
    public var debugDescription: String {
        errorDescription ?? String(describing: self)
    }
}
