// VMEngine.swift — VM lifecycle management protocol.
// VortexCore

import Foundation

/// Protocol defining the lifecycle operations for a virtual machine engine.
///
/// Conforming types manage the full lifecycle of a VM: creation from a
/// configuration, start/stop, pause/resume, and state save/restore.
/// All operations are async and may throw `VortexError`.
public protocol VMEngine: AnyObject, Sendable {

    /// A publisher-style callback or delegate identifier for state change notifications.
    /// Implementations should provide a mechanism to observe state transitions.
    var currentState: VMState { get async }

    /// Creates a new VM instance from the given configuration.
    ///
    /// This prepares the hypervisor resources (vCPUs, memory regions, devices)
    /// but does not start execution. The VM will be in the `.stopped` state
    /// after this call succeeds.
    ///
    /// - Parameter configuration: The full VM configuration.
    /// - Throws: `VortexError` if resource allocation fails.
    func create(from configuration: VMConfiguration) async throws

    /// Starts the VM, transitioning from `.stopped` to `.running`.
    ///
    /// The VM must have been previously created via `create(from:)`.
    ///
    /// - Throws: `VortexError.invalidStateTransition` if the VM is not stopped.
    func start() async throws

    /// Requests a graceful shutdown of the VM.
    ///
    /// The VM transitions to `.stopping` and then `.stopped` once the guest
    /// has completed its shutdown sequence. If the guest does not shut down
    /// within a reasonable timeout, callers may need to call `forceStop()`.
    ///
    /// - Throws: `VortexError.invalidStateTransition` if the VM cannot be stopped.
    func stop() async throws

    /// Immediately terminates the VM without waiting for guest cooperation.
    ///
    /// This is the equivalent of pulling the power cord. Use only when
    /// `stop()` fails or the guest is unresponsive.
    ///
    /// - Throws: `VortexError` if the VM is not in a stoppable state.
    func forceStop() async throws

    /// Pauses VM execution, freezing all vCPUs.
    ///
    /// The VM transitions from `.running` to `.paused`. Guest memory and
    /// device state are preserved in host memory.
    ///
    /// - Throws: `VortexError.invalidStateTransition` if the VM is not running.
    func pause() async throws

    /// Resumes a paused VM, transitioning from `.paused` to `.running`.
    ///
    /// - Throws: `VortexError.invalidStateTransition` if the VM is not paused.
    func resume() async throws

    /// Saves the current VM state (memory + device state) to the given path.
    ///
    /// The VM should typically be paused before calling this to ensure a
    /// consistent snapshot.
    ///
    /// - Parameter path: The filesystem path to write the state to.
    /// - Throws: `VortexError.snapshotFailed` on I/O or serialization failure.
    func saveState(to path: String) async throws

    /// Restores VM state from a previously saved snapshot.
    ///
    /// The VM must be in the `.stopped` state. After restoration it will
    /// be in the `.paused` state, ready to be resumed.
    ///
    /// - Parameter path: The filesystem path to read the state from.
    /// - Throws: `VortexError.snapshotFailed` if the state file is invalid or missing.
    func restoreState(from path: String) async throws
}
