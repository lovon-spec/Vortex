// VMState.swift — Runtime lifecycle state for a virtual machine.
// VortexCore

/// Represents the current runtime state of a virtual machine.
public enum VMState: String, Codable, Sendable, CaseIterable {
    /// The VM is not running.
    case stopped

    /// The VM is in the process of booting.
    case starting

    /// The VM is actively executing.
    case running

    /// The VM is suspended in memory but not executing.
    case paused

    /// The VM has been asked to shut down and is in the process of stopping.
    case stopping

    /// The VM encountered a fatal error and cannot continue.
    case error
}

// MARK: - Convenience

extension VMState {
    /// Whether the VM is in a state where it can accept a start command.
    public var canStart: Bool {
        self == .stopped || self == .error
    }

    /// Whether the VM is in a state where it can be paused.
    public var canPause: Bool {
        self == .running
    }

    /// Whether the VM is in a state where it can be resumed.
    public var canResume: Bool {
        self == .paused
    }

    /// Whether the VM is in a state where it can be stopped.
    public var canStop: Bool {
        self == .running || self == .paused
    }

    /// Whether the VM is currently consuming host resources (CPU/memory).
    public var isActive: Bool {
        self == .starting || self == .running || self == .paused || self == .stopping
    }
}
