// VMLifecycle.swift -- Higher-level lifecycle state machine.
// VortexHV

import Foundation

// MARK: - VM Lifecycle State

/// Thread-safe lifecycle state machine for a virtual machine.
/// This mirrors VortexCore's VMState but is owned by the HV layer and includes
/// transition validation.
public final class VMLifecycle: @unchecked Sendable {
    public enum State: String, Sendable {
        case stopped
        case starting
        case running
        case paused
        case stopping
        case error
    }

    private let lock = NSLock()
    private var _state: State = .stopped
    private var _errorMessage: String?

    /// Callback invoked on every state transition (new state, old state).
    public var onStateChange: ((State, State) -> Void)?

    public init() {}

    /// The current state.
    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// The error message if in `.error` state.
    public var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return _errorMessage
    }

    // MARK: - Transitions

    /// Attempt to transition to `.starting`. Valid from `.stopped` or `.error`.
    public func transitionToStarting() throws {
        try transition(to: .starting, from: [.stopped, .error])
    }

    /// Transition to `.running`. Valid from `.starting`.
    public func transitionToRunning() throws {
        try transition(to: .running, from: [.starting])
    }

    /// Transition to `.paused`. Valid from `.running`.
    public func transitionToPaused() throws {
        try transition(to: .paused, from: [.running])
    }

    /// Resume from `.paused` to `.running`.
    public func transitionToResumed() throws {
        try transition(to: .running, from: [.paused])
    }

    /// Transition to `.stopping`. Valid from `.running` or `.paused`.
    public func transitionToStopping() throws {
        try transition(to: .stopping, from: [.running, .paused])
    }

    /// Transition to `.stopped`. Valid from `.stopping`.
    public func transitionToStopped() throws {
        try transition(to: .stopped, from: [.stopping])
    }

    /// Transition to `.error` from any active state.
    public func transitionToError(message: String) {
        lock.lock()
        let old = _state
        _state = .error
        _errorMessage = message
        lock.unlock()
        onStateChange?(.error, old)
    }

    /// Force reset to `.stopped` (e.g., after cleanup).
    public func forceStop() {
        lock.lock()
        let old = _state
        _state = .stopped
        _errorMessage = nil
        lock.unlock()
        if old != .stopped {
            onStateChange?(.stopped, old)
        }
    }

    // MARK: - Private

    private func transition(to newState: State, from validStates: Set<State>) throws {
        lock.lock()
        let current = _state
        guard validStates.contains(current) else {
            lock.unlock()
            throw VMLifecycleError.invalidTransition(from: current, to: newState)
        }
        _state = newState
        if newState != .error {
            _errorMessage = nil
        }
        lock.unlock()
        onStateChange?(newState, current)
    }
}

// MARK: - Errors

public enum VMLifecycleError: Error, CustomStringConvertible {
    case invalidTransition(from: VMLifecycle.State, to: VMLifecycle.State)

    public var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            return "Invalid VM state transition from '\(from.rawValue)' to '\(to.rawValue)'"
        }
    }
}
