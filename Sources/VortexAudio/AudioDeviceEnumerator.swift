// AudioDeviceEnumerator.swift — List all host audio input/output devices.
// VortexAudio
//
// Uses the CoreAudio HAL (Hardware Abstraction Layer) API to enumerate audio
// devices, classify them as input/output, and watch for hot-plug events.

import CoreAudio
import Foundation

// MARK: - AudioHostDevice

/// Describes a single CoreAudio host audio device.
public struct AudioHostDevice: Sendable, Hashable, CustomStringConvertible {
    /// The CoreAudio `AudioDeviceID` for this device.
    public let deviceID: AudioDeviceID

    /// Persistent UID string (survives reboots, e.g. `"BuiltInSpeakerDevice"`).
    public let uid: String

    /// Human-readable name (e.g. `"MacBook Pro Speakers"`).
    public let name: String

    /// Whether this device has input (capture) streams.
    public let isInput: Bool

    /// Whether this device has output (playback) streams.
    public let isOutput: Bool

    public var description: String {
        let direction: String
        switch (isInput, isOutput) {
        case (true, true):   direction = "input+output"
        case (true, false):  direction = "input"
        case (false, true):  direction = "output"
        case (false, false): direction = "none"
        }
        return "AudioHostDevice(\(name), uid=\(uid), id=\(deviceID), \(direction))"
    }
}

// MARK: - AudioDeviceEnumerator

/// Enumerates CoreAudio hardware devices on the host.
///
/// This class queries the Audio Object system for all audio devices, retrieves
/// their names, UIDs, and stream configurations, and can watch for hot-plug
/// events (devices added or removed).
public final class AudioDeviceEnumerator: @unchecked Sendable {

    /// Callback invoked when the set of audio devices changes (hot-plug).
    /// The array contains the current full list of devices after the change.
    public typealias DeviceChangeHandler = @Sendable ([AudioHostDevice]) -> Void

    private var changeHandler: DeviceChangeHandler?
    private var listenerInstalled = false

    // MARK: - Init / Deinit

    public init() {}

    deinit {
        removeDeviceListListener()
    }

    // MARK: - Enumerate devices

    /// Returns all audio devices currently connected to the host.
    public func allDevices() throws -> [AudioHostDevice] {
        let deviceIDs = try getDeviceIDs()
        return deviceIDs.compactMap { id in
            do {
                return try deviceInfo(for: id)
            } catch {
                // Skip devices we cannot query (e.g., already disconnected).
                return nil
            }
        }
    }

    /// Returns only output-capable devices.
    public func outputDevices() throws -> [AudioHostDevice] {
        try allDevices().filter(\.isOutput)
    }

    /// Returns only input-capable devices.
    public func inputDevices() throws -> [AudioHostDevice] {
        try allDevices().filter(\.isInput)
    }

    /// Find a device by its persistent UID string.
    public func device(uid: String) throws -> AudioHostDevice? {
        try allDevices().first { $0.uid == uid }
    }

    /// Resolve an `AudioDeviceID` from a persistent UID string.
    /// Uses the CoreAudio translation property for efficiency.
    public func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        var cfUID: CFString = uid as CFString
        var deviceID: AudioDeviceID = kAudioObjectUnknown

        let status: OSStatus = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { devPtr in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(devPtr),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )

                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDeviceForUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }

        if status != noErr || deviceID == kAudioObjectUnknown {
            return nil
        }
        return deviceID
    }

    // MARK: - Hot-plug listening

    /// Start watching for device list changes.
    ///
    /// The handler is called on an arbitrary thread whenever devices are
    /// added or removed. The handler receives the updated full device list.
    public func startWatching(handler: @escaping DeviceChangeHandler) {
        changeHandler = handler
        installDeviceListListener()
    }

    /// Stop watching for device list changes.
    public func stopWatching() {
        removeDeviceListListener()
        changeHandler = nil
    }

    // MARK: - Private: query helpers

    /// Get the list of all AudioDeviceIDs from the system.
    private func getDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw AudioDeviceError.coreAudioError(status, "GetPropertyDataSize for device list")
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        if deviceCount == 0 { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else {
            throw AudioDeviceError.coreAudioError(status, "GetPropertyData for device list")
        }

        return deviceIDs
    }

    /// Build an `AudioHostDevice` for a single device ID.
    private func deviceInfo(for deviceID: AudioDeviceID) throws -> AudioHostDevice {
        let uid = try getStringProperty(deviceID: deviceID,
                                        selector: kAudioDevicePropertyDeviceUID)
        let name = try getStringProperty(deviceID: deviceID,
                                         selector: kAudioDevicePropertyDeviceNameCFString)
        let inputStreams = streamCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputStreams = streamCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)

        return AudioHostDevice(
            deviceID: deviceID,
            uid: uid,
            name: name,
            isInput: inputStreams > 0,
            isOutput: outputStreams > 0
        )
    }

    /// Read a CFString property from a device and return it as a Swift String.
    private func getStringProperty(deviceID: AudioDeviceID,
                                   selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr, let cfString = value else {
            throw AudioDeviceError.coreAudioError(status,
                "GetPropertyData for selector \(selector) on device \(deviceID)")
        }
        return cfString.takeRetainedValue() as String
    }

    /// Count the number of streams in a given scope (input or output).
    private func streamCount(deviceID: AudioDeviceID,
                             scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { return 0 }

        return Int(dataSize) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: - Private: listener

    private func installDeviceListListener() {
        guard !listenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil  // dispatch queue — nil = main queue
        ) { [weak self] _, _ in
            guard let self = self else { return }
            if let handler = self.changeHandler {
                let devices = (try? self.allDevices()) ?? []
                handler(devices)
            }
        }

        if status == noErr {
            listenerInstalled = true
        }
    }

    private func removeDeviceListListener() {
        guard listenerInstalled else { return }
        // Note: We cannot remove a block-based listener without storing
        // the block reference. In practice, the listener is scoped to the
        // lifetime of this object. Setting the handler to nil ensures the
        // callback becomes a no-op.
        listenerInstalled = false
    }
}

// MARK: - AudioDeviceError

/// Errors produced by the audio device layer.
public enum AudioDeviceError: Error, Sendable, CustomStringConvertible {
    /// A CoreAudio API call returned a non-zero OSStatus.
    case coreAudioError(OSStatus, String)

    /// The requested device UID was not found among connected devices.
    case deviceNotFound(uid: String)

    /// The device disappeared while in use.
    case deviceDisconnected(uid: String)

    /// The requested audio format is not supported by the device.
    case unsupportedFormat(String)

    /// AudioUnit lifecycle error (init, start, stop, dispose).
    case audioUnitError(OSStatus, String)

    /// AudioConverter error.
    case converterError(OSStatus, String)

    public var description: String {
        switch self {
        case .coreAudioError(let status, let context):
            return "CoreAudio error \(status) (\(fourCharCode(status))): \(context)"
        case .deviceNotFound(let uid):
            return "Audio device not found: \(uid)"
        case .deviceDisconnected(let uid):
            return "Audio device disconnected: \(uid)"
        case .unsupportedFormat(let detail):
            return "Unsupported audio format: \(detail)"
        case .audioUnitError(let status, let context):
            return "AudioUnit error \(status) (\(fourCharCode(status))): \(context)"
        case .converterError(let status, let context):
            return "AudioConverter error \(status) (\(fourCharCode(status))): \(context)"
        }
    }
}

/// Convert an OSStatus (FourCC) to a readable string.
private func fourCharCode(_ status: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8((UInt32(bitPattern: status) >> 24) & 0xFF),
        UInt8((UInt32(bitPattern: status) >> 16) & 0xFF),
        UInt8((UInt32(bitPattern: status) >> 8) & 0xFF),
        UInt8(UInt32(bitPattern: status) & 0xFF),
    ]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
    if printable {
        return "'" + String(bytes.map { Character(UnicodeScalar($0)) }) + "'"
    }
    return String(status)
}
