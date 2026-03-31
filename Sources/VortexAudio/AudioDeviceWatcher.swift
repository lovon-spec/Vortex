// AudioDeviceWatcher.swift — Monitor device changes and disconnect events.
// VortexAudio
//
// Watches the CoreAudio system for device list changes (hot-plug), default
// device changes (informational), and per-device alive status for devices
// that are actively used by VMs.

import CoreAudio
import Foundation

// MARK: - AudioDeviceEvent

/// Events emitted by the device watcher.
public enum AudioDeviceEvent: Sendable {
    /// The global device list changed (devices added or removed).
    case deviceListChanged

    /// A specific device that was being watched has disconnected.
    case deviceDisconnected(deviceID: AudioDeviceID, uid: String)

    /// The system default output device changed. Informational only.
    case defaultOutputChanged(deviceID: AudioDeviceID)

    /// The system default input device changed. Informational only.
    case defaultInputChanged(deviceID: AudioDeviceID)
}

// MARK: - AudioDeviceWatcher

/// Monitors CoreAudio for device changes relevant to VM audio routing.
///
/// Watches three categories:
/// 1. Global device list changes (add/remove).
/// 2. Default device changes (informational — Vortex never uses defaults).
/// 3. Per-device alive status for devices actively assigned to VMs.
public final class AudioDeviceWatcher: @unchecked Sendable {

    /// Callback type for device events.
    public typealias EventHandler = @Sendable (AudioDeviceEvent) -> Void

    private let eventHandler: EventHandler
    private let enumerator: AudioDeviceEnumerator

    /// Set of device IDs we are watching for disconnect.
    private var watchedDevices: Set<AudioDeviceID> = []

    /// Device UIDs cached so we can report them on disconnect.
    private var deviceUIDs: [AudioDeviceID: String] = [:]

    /// Whether global listeners are installed.
    private var isWatching = false

    /// Synchronization for mutable state.
    private let lock = NSLock()

    // MARK: - Init / Deinit

    /// Creates a device watcher.
    ///
    /// - Parameters:
    ///   - enumerator: The device enumerator to use for UID lookups.
    ///   - handler: Called on an arbitrary thread when a device event occurs.
    public init(enumerator: AudioDeviceEnumerator, handler: @escaping EventHandler) {
        self.enumerator = enumerator
        self.eventHandler = handler
    }

    deinit {
        stopWatching()
    }

    // MARK: - Global watching

    /// Start watching for global device list and default device changes.
    public func startWatching() {
        lock.lock()
        defer { lock.unlock() }
        guard !isWatching else { return }

        installGlobalListeners()
        isWatching = true
    }

    /// Stop all watching.
    public func stopWatching() {
        lock.lock()
        defer { lock.unlock() }
        guard isWatching else { return }

        // Per-device watchers will become no-ops since we clear the set.
        watchedDevices.removeAll()
        deviceUIDs.removeAll()
        isWatching = false
    }

    // MARK: - Per-device watching

    /// Start watching a specific device for disconnect (device-is-alive).
    ///
    /// Call this when a VM starts using a device. If the device disconnects,
    /// `EventHandler` will receive `.deviceDisconnected`.
    ///
    /// - Parameters:
    ///   - deviceID: The device to watch.
    ///   - uid: The device UID (for reporting purposes).
    public func watchDevice(deviceID: AudioDeviceID, uid: String) {
        lock.lock()
        let alreadyWatched = watchedDevices.contains(deviceID)
        watchedDevices.insert(deviceID)
        deviceUIDs[deviceID] = uid
        lock.unlock()

        guard !alreadyWatched else { return }
        installAliveListener(for: deviceID)
    }

    /// Stop watching a specific device (e.g., when a VM releases it).
    public func unwatchDevice(deviceID: AudioDeviceID) {
        lock.lock()
        watchedDevices.remove(deviceID)
        deviceUIDs.removeValue(forKey: deviceID)
        lock.unlock()
    }

    // MARK: - Private: install listeners

    private func installGlobalListeners() {
        // 1. Device list changes (hot-plug).
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            nil
        ) { [weak self] _, _ in
            self?.eventHandler(.deviceListChanged)
        }

        // 2. Default output device changes (informational).
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            nil
        ) { [weak self] _, _ in
            guard let self = self else { return }
            if let id = self.getDefaultDevice(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            ) {
                self.eventHandler(.defaultOutputChanged(deviceID: id))
            }
        }

        // 3. Default input device changes (informational).
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            nil
        ) { [weak self] _, _ in
            guard let self = self else { return }
            if let id = self.getDefaultDevice(
                selector: kAudioHardwarePropertyDefaultInputDevice
            ) {
                self.eventHandler(.defaultInputChanged(deviceID: id))
            }
        }
    }

    private func installAliveListener(for deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            nil
        ) { [weak self] objectID, _ in
            guard let self = self else { return }

            // Check if the device is still alive.
            let alive = self.isDeviceAlive(objectID)
            if !alive {
                self.lock.lock()
                let uid = self.deviceUIDs[objectID] ?? "unknown"
                let wasWatched = self.watchedDevices.remove(objectID) != nil
                self.deviceUIDs.removeValue(forKey: objectID)
                self.lock.unlock()

                if wasWatched {
                    self.eventHandler(.deviceDisconnected(
                        deviceID: objectID,
                        uid: uid
                    ))
                }
            }
        }
    }

    // MARK: - Private: property helpers

    private func getDefaultDevice(
        selector: AudioObjectPropertySelector
    ) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        if status == noErr && deviceID != kAudioObjectUnknown {
            return deviceID
        }
        return nil
    }

    private func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &isAlive
        )

        // If we cannot query, assume dead.
        return status == noErr && isAlive != 0
    }
}
