// AudioRouter.swift — Per-VM audio routing coordinator.
// VortexAudio
//
// Owns one AudioOutputUnit and one AudioInputUnit per VM. Resolves device
// UIDs to AudioDeviceIDs, manages lifecycle, and supports hot-swapping
// devices while audio is running.

import CoreAudio
import Foundation
import VortexCore

// MARK: - AudioRouter

/// Per-VM audio routing coordinator.
///
/// Each running VM gets one `AudioRouter`. It manages the output path
/// (VM -> ring buffer -> host speaker) and the input path (host mic ->
/// ring buffer -> VM), resolving the user's device UID selections to
/// concrete CoreAudio device IDs and handling hot-swap.
///
/// Usage:
/// ```swift
/// let router = AudioRouter(vmID: "my-vm")
/// try router.configure(
///     output: AudioEndpointConfig(hostDeviceUID: "BlackHole16ch_UID",
///                                  hostDeviceName: "BlackHole 16ch"),
///     input: nil
/// )
/// try router.start()
/// // ... VM writes PCM to router.outputRingBuffer ...
/// router.stop()
/// ```
public final class AudioRouter: @unchecked Sendable {

    // MARK: - Properties

    /// Identifier for logging / diagnostics.
    public let vmID: String

    /// The current output unit, if configured.
    public private(set) var outputUnit: AudioOutputUnit?

    /// The current input unit, if configured.
    public private(set) var inputUnit: AudioInputUnit?

    /// Device enumerator for UID -> ID resolution.
    private let enumerator: AudioDeviceEnumerator

    /// Device watcher for disconnect notifications.
    private let watcher: AudioDeviceWatcher

    /// Whether the router is currently active (start has been called).
    public private(set) var isRunning: Bool = false

    /// Current output configuration, if any.
    public private(set) var outputConfig: AudioEndpointConfig?

    /// Current input configuration, if any.
    public private(set) var inputConfig: AudioEndpointConfig?

    /// Sample rate used for audio units (default 48 kHz).
    public var sampleRate: Float64 = 48000

    /// Channel count (default 2 for stereo).
    public var channelCount: UInt32 = 2

    /// Bit depth — 16 for Int16, 32 for Float32 (default 32).
    public var bitDepth: UInt32 = 32

    /// Callback invoked when a device used by this router disconnects.
    /// Parameters: direction (.output / .input), device UID.
    public var onDeviceDisconnected: ((_ direction: AudioDirection,
                                       _ uid: String) -> Void)?

    /// Callback invoked when a previously-disconnected device reappears.
    /// Parameters: direction (.output / .input), device UID.
    public var onDeviceReconnected: ((_ direction: AudioDirection,
                                      _ uid: String) -> Void)?

    /// Set of device UIDs that are currently disconnected while this router
    /// was running. Used to auto-recover when the device reappears.
    private var disconnectedOutputUID: String?
    private var disconnectedInputUID: String?

    // MARK: - Init / Deinit

    /// Creates a router for a specific VM.
    ///
    /// - Parameters:
    ///   - vmID: An identifier for this VM (used in logs/diagnostics).
    ///   - enumerator: Shared device enumerator (default: creates a new one).
    public init(vmID: String, enumerator: AudioDeviceEnumerator = AudioDeviceEnumerator()) {
        self.vmID = vmID
        self.enumerator = enumerator

        // Placeholder watcher (needed because `self` is not yet available
        // during init for a weak capture). Immediately replaced below.
        self.watcher = AudioDeviceWatcher(enumerator: enumerator) { _ in }

        // Now create the real watcher with a proper weak self capture.
        let actualWatcher = AudioDeviceWatcher(enumerator: enumerator) { [weak self] event in
            self?.handleDeviceEvent(event)
        }
        actualWatcher.startWatching()
        self._activeWatcher = actualWatcher
    }

    /// Internal reference to the actually-active watcher.
    private var _activeWatcher: AudioDeviceWatcher?

    deinit {
        stop()
        _activeWatcher?.stopWatching()
    }

    // MARK: - Configuration

    /// Configure output and/or input routing.
    ///
    /// If a configuration is `nil`, that direction is disabled. If a
    /// configuration specifies a device UID, it is resolved to an
    /// `AudioDeviceID` and an AudioUnit is created.
    ///
    /// - Parameters:
    ///   - output: Output (playback) endpoint configuration, or `nil`.
    ///   - input: Input (capture) endpoint configuration, or `nil`.
    public func configure(
        output: AudioEndpointConfig?,
        input: AudioEndpointConfig?
    ) throws {
        // Tear down existing units if reconfiguring.
        let wasRunning = isRunning
        if wasRunning { stop() }

        // Output.
        if let outputCfg = output {
            let deviceID = try resolveDevice(uid: outputCfg.hostDeviceUID)
            self.outputUnit = try AudioOutputUnit(
                deviceID: deviceID,
                sampleRate: sampleRate,
                channels: channelCount,
                bitDepth: bitDepth
            )
            self.outputConfig = outputCfg
            _activeWatcher?.watchDevice(deviceID: deviceID, uid: outputCfg.hostDeviceUID)
        } else {
            self.outputUnit = nil
            self.outputConfig = nil
        }

        // Input.
        if let inputCfg = input {
            let deviceID = try resolveDevice(uid: inputCfg.hostDeviceUID)
            self.inputUnit = try AudioInputUnit(
                deviceID: deviceID,
                sampleRate: sampleRate,
                channels: channelCount,
                bitDepth: bitDepth
            )
            self.inputConfig = inputCfg
            _activeWatcher?.watchDevice(deviceID: deviceID, uid: inputCfg.hostDeviceUID)
        } else {
            self.inputUnit = nil
            self.inputConfig = nil
        }

        if wasRunning {
            try start()
        }
    }

    // MARK: - Lifecycle

    /// Start audio playback and/or capture.
    public func start() throws {
        if let out = outputUnit, !out.isRunning {
            try out.start()
        }
        if let inp = inputUnit, !inp.isRunning {
            try inp.start()
        }
        isRunning = true
    }

    /// Stop audio playback and capture.
    public func stop() {
        outputUnit?.stop()
        inputUnit?.stop()
        isRunning = false
    }

    // MARK: - Hot-swap

    /// Hot-swap the output device while running.
    ///
    /// If the router is currently playing, audio will be interrupted briefly
    /// during the device switch.
    ///
    /// - Parameter endpoint: New output endpoint configuration.
    public func switchOutput(to endpoint: AudioEndpointConfig) throws {
        let deviceID = try resolveDevice(uid: endpoint.hostDeviceUID)

        if let existing = outputUnit {
            // Unwatch old device.
            if let oldConfig = outputConfig {
                _activeWatcher?.unwatchDevice(deviceID: existing.deviceID)
                _ = oldConfig // suppress unused warning
            }
            try existing.switchDevice(to: deviceID, restart: isRunning)
        } else {
            // No existing output unit — create one.
            let unit = try AudioOutputUnit(
                deviceID: deviceID,
                sampleRate: sampleRate,
                channels: channelCount,
                bitDepth: bitDepth
            )
            self.outputUnit = unit
            if isRunning { try unit.start() }
        }

        self.outputConfig = endpoint
        _activeWatcher?.watchDevice(deviceID: deviceID, uid: endpoint.hostDeviceUID)
    }

    /// Hot-swap the input device while running.
    ///
    /// - Parameter endpoint: New input endpoint configuration.
    public func switchInput(to endpoint: AudioEndpointConfig) throws {
        let deviceID = try resolveDevice(uid: endpoint.hostDeviceUID)

        if let existing = inputUnit {
            if let oldConfig = inputConfig {
                _activeWatcher?.unwatchDevice(deviceID: existing.deviceID)
                _ = oldConfig
            }
            try existing.switchDevice(to: deviceID, restart: isRunning)
        } else {
            let unit = try AudioInputUnit(
                deviceID: deviceID,
                sampleRate: sampleRate,
                channels: channelCount,
                bitDepth: bitDepth
            )
            self.inputUnit = unit
            if isRunning { try unit.start() }
        }

        self.inputConfig = endpoint
        _activeWatcher?.watchDevice(deviceID: deviceID, uid: endpoint.hostDeviceUID)
    }

    // MARK: - Ring buffer access

    /// The ring buffer for the output path.
    ///
    /// The device emulation layer writes guest PCM here; the AudioUnit
    /// render callback reads from it.
    public var outputRingBuffer: AudioRingBuffer? {
        outputUnit?.ringBuffer
    }

    /// The ring buffer for the input path.
    ///
    /// The AudioUnit input callback writes captured PCM here; the device
    /// emulation layer reads from it.
    public var inputRingBuffer: AudioRingBuffer? {
        inputUnit?.ringBuffer
    }

    // MARK: - Private: resolution

    /// Resolve a device UID string to an AudioDeviceID.
    private func resolveDevice(uid: String) throws -> AudioDeviceID {
        // First try the efficient translation property.
        if let id = try enumerator.deviceID(forUID: uid) {
            return id
        }
        // Fallback: full enumeration.
        if let device = try enumerator.device(uid: uid) {
            return device.deviceID
        }
        throw AudioDeviceError.deviceNotFound(uid: uid)
    }

    // MARK: - Device disconnect / reconnect

    /// Handle a device disconnect for a specific UID.
    ///
    /// Stops the affected AudioUnit and records the UID so that a future
    /// reconnection can auto-recover. The router remains in the `isRunning`
    /// state so that reconnection can restart without a full reconfigure.
    ///
    /// - Parameter deviceUID: The UID of the device that disconnected.
    public func handleDeviceDisconnect(deviceUID: String) {
        if let outCfg = outputConfig, outCfg.hostDeviceUID == deviceUID {
            print("[AudioRouter:\(vmID)] Output device disconnected: \(deviceUID)")
            outputUnit?.stop()
            disconnectedOutputUID = deviceUID
            onDeviceDisconnected?(.output, deviceUID)
        }
        if let inCfg = inputConfig, inCfg.hostDeviceUID == deviceUID {
            print("[AudioRouter:\(vmID)] Input device disconnected: \(deviceUID)")
            inputUnit?.stop()
            disconnectedInputUID = deviceUID
            onDeviceDisconnected?(.input, deviceUID)
        }
    }

    /// Handle a device reconnect for a specific UID.
    ///
    /// Re-resolves the UID to a (potentially new) AudioDeviceID,
    /// reconfigures the affected AudioUnit, and restarts it if the router
    /// was running before the disconnect.
    ///
    /// - Parameter deviceUID: The UID of the device that reappeared.
    public func handleDeviceReconnect(deviceUID: String) {
        if disconnectedOutputUID == deviceUID, let outCfg = outputConfig {
            print("[AudioRouter:\(vmID)] Output device reconnected: \(deviceUID)")
            disconnectedOutputUID = nil
            do {
                let newDeviceID = try resolveDevice(uid: deviceUID)
                if let existing = outputUnit {
                    try existing.switchDevice(to: newDeviceID, restart: isRunning)
                } else {
                    let unit = try AudioOutputUnit(
                        deviceID: newDeviceID,
                        sampleRate: sampleRate,
                        channels: channelCount,
                        bitDepth: bitDepth
                    )
                    self.outputUnit = unit
                    if isRunning { try unit.start() }
                }
                _activeWatcher?.watchDevice(deviceID: newDeviceID, uid: outCfg.hostDeviceUID)
                onDeviceReconnected?(.output, deviceUID)
            } catch {
                print("[AudioRouter:\(vmID)] Failed to reconnect output device \(deviceUID): \(error)")
                // Keep the UID tracked so the watcher will try again.
                disconnectedOutputUID = deviceUID
                _activeWatcher?.trackDisconnectedUID(deviceUID)
            }
        }

        if disconnectedInputUID == deviceUID, let inCfg = inputConfig {
            print("[AudioRouter:\(vmID)] Input device reconnected: \(deviceUID)")
            disconnectedInputUID = nil
            do {
                let newDeviceID = try resolveDevice(uid: deviceUID)
                if let existing = inputUnit {
                    try existing.switchDevice(to: newDeviceID, restart: isRunning)
                } else {
                    let unit = try AudioInputUnit(
                        deviceID: newDeviceID,
                        sampleRate: sampleRate,
                        channels: channelCount,
                        bitDepth: bitDepth
                    )
                    self.inputUnit = unit
                    if isRunning { try unit.start() }
                }
                _activeWatcher?.watchDevice(deviceID: newDeviceID, uid: inCfg.hostDeviceUID)
                onDeviceReconnected?(.input, deviceUID)
            } catch {
                print("[AudioRouter:\(vmID)] Failed to reconnect input device \(deviceUID): \(error)")
                disconnectedInputUID = deviceUID
                _activeWatcher?.trackDisconnectedUID(deviceUID)
            }
        }
    }

    /// Whether the output device is currently disconnected.
    public var isOutputDisconnected: Bool {
        disconnectedOutputUID != nil
    }

    /// Whether the input device is currently disconnected.
    public var isInputDisconnected: Bool {
        disconnectedInputUID != nil
    }

    // MARK: - Private: device events

    private func handleDeviceEvent(_ event: AudioDeviceEvent) {
        switch event {
        case .deviceDisconnected(_, let uid):
            handleDeviceDisconnect(deviceUID: uid)

        case .deviceReappeared(_, let uid):
            handleDeviceReconnect(deviceUID: uid)

        case .deviceListChanged:
            // Reconnection is handled via .deviceReappeared, which the
            // watcher emits after checking disconnectedUIDs on list change.
            break

        case .defaultOutputChanged, .defaultInputChanged:
            // Informational only — Vortex never uses system defaults.
            break
        }
    }
}

// MARK: - AudioDirection

/// Direction of audio flow.
public enum AudioDirection: String, Sendable {
    case input
    case output
}
