// AudioInterceptor.swift — CoreAudio function interposition for VZ audio redirect.
// VortexInterception
//
// Uses the fishhook technique (Mach-O lazy symbol pointer rebinding) to
// intercept CoreAudio C functions at runtime. When Virtualization.framework
// creates AudioUnit instances for a macOS VM's virtio-snd device, our hooks
// replace the target device ID with the one we specify, achieving per-VM
// audio routing without modifying host defaults.
//
// Thread safety: All mutable state is protected by os_unfair_lock, which is
// appropriate for the high-frequency, low-contention access pattern here.
// VZ may create AudioUnits on arbitrary threads.

import AudioToolbox
import CoreAudio
import CFishHook
import Foundation
import os.lock

// MARK: - AudioInterceptor

/// Intercepts CoreAudio AudioUnit creation and property-set calls made by
/// Virtualization.framework, redirecting audio to a specific host device.
///
/// ## Usage
///
/// ```swift
/// // Before starting the VZ virtual machine:
/// try AudioInterceptor.install(
///     targetOutputDeviceID: myOutputDeviceID,
///     targetInputDeviceID: myInputDeviceID
/// )
///
/// // ... start VM, VZ creates AudioUnits internally ...
///
/// // When the VM is stopped:
/// AudioInterceptor.uninstall()
/// ```
///
/// ## How it works
///
/// 1. `AudioComponentInstanceNew` is hooked to track every AudioUnit VZ creates.
/// 2. `AudioUnitSetProperty` is hooked to intercept writes to
///    `kAudioOutputUnitProperty_CurrentDevice`, replacing the device ID with
///    our target.
/// 3. `AudioUnitGetProperty` is optionally hooked to report back our target
///    device ID when queried for the current device.
///
/// ## Threading model
///
/// `install()` and `uninstall()` must be called from the main thread (or at
/// least serialized with respect to VM lifecycle). The hooks themselves are
/// safe to call from any thread -- VZ's internal AudioUnit creation may
/// happen on worker threads.
public final class AudioInterceptor: @unchecked Sendable {

    // MARK: - Types

    /// Snapshot of interceptor state for diagnostics.
    public struct DiagnosticInfo: Sendable, CustomStringConvertible {
        /// Whether hooks are currently installed.
        public let isInstalled: Bool

        /// Number of AudioUnit instances tracked.
        public let trackedUnitCount: Int

        /// The target output device ID (0 = not set).
        public let targetOutputDeviceID: AudioDeviceID

        /// The target input device ID (0 = not set).
        public let targetInputDeviceID: AudioDeviceID

        /// Number of `AudioComponentInstanceNew` calls intercepted.
        public let instanceNewCallCount: UInt64

        /// Number of `AudioUnitSetProperty` calls where we replaced the device.
        public let deviceRedirectCount: UInt64

        public var description: String {
            """
            AudioInterceptor(installed=\(isInstalled), \
            tracked=\(trackedUnitCount), \
            output=\(targetOutputDeviceID), \
            input=\(targetInputDeviceID), \
            newCalls=\(instanceNewCallCount), \
            redirects=\(deviceRedirectCount))
            """
        }
    }

    // MARK: - Singleton state

    /// Lock protecting all mutable state. os_unfair_lock is the right choice:
    /// it is the fastest user-space lock on macOS and does not priority-invert.
    private static var lock = os_unfair_lock()

    /// Whether hooks are currently installed.
    private static var installed = false

    /// Target output device ID to substitute. 0 means "no override".
    private static var targetOutputDeviceID: AudioDeviceID = 0

    /// Target input device ID to substitute. 0 means "no override".
    private static var targetInputDeviceID: AudioDeviceID = 0

    /// Set of AudioUnit instances created while hooks are active.
    /// We track these so we can distinguish VZ-created units from any others
    /// that might exist in the process (e.g., our own VortexAudio units).
    private static var trackedUnits: Set<OpaquePointer> = []

    /// Counters for diagnostics.
    private static var instanceNewCallCount: UInt64 = 0
    private static var deviceRedirectCount: UInt64 = 0

    /// Logger for interception events.
    private static let logger = Logger(
        subsystem: "com.vortex.interception",
        category: "AudioInterceptor"
    )

    // MARK: - Original function pointers (filled by fishhook)

    // These are typed as optional C function pointers. fishhook writes the
    // original function address here before patching.

    /// Original `AudioComponentInstanceNew`.
    private static var orig_AudioComponentInstanceNew:
        (@convention(c) (AudioComponent, UnsafeMutablePointer<AudioComponentInstance?>) -> OSStatus)?

    /// Original `AudioUnitSetProperty`.
    private static var orig_AudioUnitSetProperty:
        (@convention(c) (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                         UnsafeRawPointer?, UInt32) -> OSStatus)?

    /// Original `AudioUnitGetProperty`.
    private static var orig_AudioUnitGetProperty:
        (@convention(c) (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                         UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>) -> OSStatus)?

    // MARK: - Public API

    /// Install CoreAudio function hooks to redirect VZ audio to specific devices.
    ///
    /// Must be called **before** starting the VZ virtual machine so that the
    /// hooks are in place when VZ creates its AudioUnit instances.
    ///
    /// - Parameters:
    ///   - targetOutputDeviceID: The `AudioDeviceID` to use for output.
    ///     Pass 0 to leave output routing unchanged.
    ///   - targetInputDeviceID: The `AudioDeviceID` to use for input.
    ///     Pass `nil` or 0 to leave input routing unchanged.
    /// - Throws: `InterceptionError.alreadyInstalled` if hooks are active,
    ///           `InterceptionError.rebindFailed` if fishhook fails.
    public static func install(
        targetOutputDeviceID: AudioDeviceID,
        targetInputDeviceID: AudioDeviceID? = nil
    ) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard !installed else {
            throw InterceptionError.alreadyInstalled
        }

        self.targetOutputDeviceID = targetOutputDeviceID
        self.targetInputDeviceID = targetInputDeviceID ?? 0
        self.trackedUnits = []
        self.instanceNewCallCount = 0
        self.deviceRedirectCount = 0

        logger.info("""
            Installing audio hooks — \
            output device: \(targetOutputDeviceID), \
            input device: \(self.targetInputDeviceID)
            """)

        // Build the rebinding table. We need raw void pointers for the C API.
        var rebindings = [
            rebinding(
                name: strdup("AudioComponentInstanceNew"),
                replacement: unsafeBitCast(
                    hook_AudioComponentInstanceNew as
                        @convention(c) (AudioComponent, UnsafeMutablePointer<AudioComponentInstance?>) -> OSStatus,
                    to: UnsafeMutableRawPointer.self
                ),
                replaced: withUnsafeMutablePointer(to: &orig_AudioComponentInstanceNew) {
                    UnsafeMutableRawPointer($0).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                }
            ),
            rebinding(
                name: strdup("AudioUnitSetProperty"),
                replacement: unsafeBitCast(
                    hook_AudioUnitSetProperty as
                        @convention(c) (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                                        UnsafeRawPointer?, UInt32) -> OSStatus,
                    to: UnsafeMutableRawPointer.self
                ),
                replaced: withUnsafeMutablePointer(to: &orig_AudioUnitSetProperty) {
                    UnsafeMutableRawPointer($0).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                }
            ),
            rebinding(
                name: strdup("AudioUnitGetProperty"),
                replacement: unsafeBitCast(
                    hook_AudioUnitGetProperty as
                        @convention(c) (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                                        UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>) -> OSStatus,
                    to: UnsafeMutableRawPointer.self
                ),
                replaced: withUnsafeMutablePointer(to: &orig_AudioUnitGetProperty) {
                    UnsafeMutableRawPointer($0).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                }
            ),
        ]

        let result = rebind_symbols(&rebindings, rebindings.count)

        // Free the strdup'd name strings.
        for i in 0..<rebindings.count {
            free(UnsafeMutableRawPointer(mutating: rebindings[i].name))
        }

        guard result == 0 else {
            logger.error("rebind_symbols failed with code \(result)")
            throw InterceptionError.rebindFailed(code: Int(result))
        }

        installed = true
        logger.info("Audio hooks installed successfully")
    }

    /// Remove the audio hooks and restore original CoreAudio functions.
    ///
    /// After calling this, any future AudioUnit operations will go through
    /// the original CoreAudio code path. AudioUnits created while hooks were
    /// active remain on whatever device they were redirected to -- this does
    /// not retroactively change them.
    public static func uninstall() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard installed else {
            logger.warning("uninstall() called but hooks are not installed")
            return
        }

        logger.info("""
            Uninstalling audio hooks — \
            tracked \(trackedUnits.count) units, \
            \(instanceNewCallCount) new calls, \
            \(deviceRedirectCount) redirects
            """)

        // Re-rebind back to the originals. This is safe because fishhook
        // will simply write the original pointer back into the symbol table.
        if let origNew = orig_AudioComponentInstanceNew {
            var rebinding_new = rebinding(
                name: strdup("AudioComponentInstanceNew"),
                replacement: unsafeBitCast(origNew, to: UnsafeMutableRawPointer.self),
                replaced: nil
            )
            rebind_symbols(&rebinding_new, 1)
            free(UnsafeMutableRawPointer(mutating: rebinding_new.name))
        }

        if let origSet = orig_AudioUnitSetProperty {
            var rebinding_set = rebinding(
                name: strdup("AudioUnitSetProperty"),
                replacement: unsafeBitCast(origSet, to: UnsafeMutableRawPointer.self),
                replaced: nil
            )
            rebind_symbols(&rebinding_set, 1)
            free(UnsafeMutableRawPointer(mutating: rebinding_set.name))
        }

        if let origGet = orig_AudioUnitGetProperty {
            var rebinding_get = rebinding(
                name: strdup("AudioUnitGetProperty"),
                replacement: unsafeBitCast(origGet, to: UnsafeMutableRawPointer.self),
                replaced: nil
            )
            rebind_symbols(&rebinding_get, 1)
            free(UnsafeMutableRawPointer(mutating: rebinding_get.name))
        }

        // Reset state.
        orig_AudioComponentInstanceNew = nil
        orig_AudioUnitSetProperty = nil
        orig_AudioUnitGetProperty = nil
        targetOutputDeviceID = 0
        targetInputDeviceID = 0
        trackedUnits = []
        installed = false

        logger.info("Audio hooks uninstalled")
    }

    /// Returns whether hooks are currently installed.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return installed
    }

    /// Returns diagnostic information about the current interception state.
    public static var diagnosticInfo: DiagnosticInfo {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return DiagnosticInfo(
            isInstalled: installed,
            trackedUnitCount: trackedUnits.count,
            targetOutputDeviceID: targetOutputDeviceID,
            targetInputDeviceID: targetInputDeviceID,
            instanceNewCallCount: instanceNewCallCount,
            deviceRedirectCount: deviceRedirectCount
        )
    }

    /// Check whether a given AudioUnit is one that we are tracking
    /// (i.e., was created while hooks were active).
    public static func isTracked(_ unit: AudioUnit) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return trackedUnits.contains(OpaquePointer(unit))
    }

    // MARK: - Hook implementations

    /// Hook for `AudioComponentInstanceNew`.
    ///
    /// Calls the original function, then records the newly created AudioUnit
    /// in our tracking set.
    private static let hook_AudioComponentInstanceNew:
        @convention(c) (AudioComponent, UnsafeMutablePointer<AudioComponentInstance?>) -> OSStatus =
    { component, instanceOut in
        // Call original.
        guard let original = orig_AudioComponentInstanceNew else {
            // Should never happen if install() succeeded.
            return OSStatus(kAudioUnitErr_FailedInitialization)
        }

        let status = original(component, instanceOut)

        if status == noErr, let instance = instanceOut.pointee {
            os_unfair_lock_lock(&lock)
            trackedUnits.insert(OpaquePointer(instance))
            instanceNewCallCount += 1
            let count = trackedUnits.count
            os_unfair_lock_unlock(&lock)

            logger.debug("""
                Intercepted AudioComponentInstanceNew — \
                instance=\(String(describing: OpaquePointer(instance))), \
                total tracked=\(count)
                """)
        }

        return status
    }

    /// Hook for `AudioUnitSetProperty`.
    ///
    /// When VZ sets `kAudioOutputUnitProperty_CurrentDevice` on a tracked
    /// AudioUnit, we substitute our target device ID. All other property
    /// sets pass through unchanged.
    private static let hook_AudioUnitSetProperty:
        @convention(c) (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                        UnsafeRawPointer?, UInt32) -> OSStatus =
    { unit, propertyID, scope, element, data, dataSize in
        guard let original = orig_AudioUnitSetProperty else {
            return OSStatus(kAudioUnitErr_FailedInitialization)
        }

        // Check if this is a device routing property on a tracked unit.
        if propertyID == kAudioOutputUnitProperty_CurrentDevice,
           dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size) {

            os_unfair_lock_lock(&lock)
            let isTrackedUnit = trackedUnits.contains(OpaquePointer(unit))
            let outDevice = targetOutputDeviceID
            let inDevice = targetInputDeviceID
            os_unfair_lock_unlock(&lock)

            if isTrackedUnit {
                // Determine which device ID to substitute based on scope.
                let substituteID: AudioDeviceID
                if scope == kAudioUnitScope_Input && inDevice != 0 {
                    substituteID = inDevice
                } else if outDevice != 0 {
                    substituteID = outDevice
                } else {
                    // No override configured for this scope; pass through.
                    return original(unit, propertyID, scope, element, data, dataSize)
                }

                // Read the original device ID being set (for logging).
                var originalDeviceID: AudioDeviceID = 0
                if let data = data {
                    originalDeviceID = data.assumingMemoryBound(to: AudioDeviceID.self).pointee
                }

                // Write our substitute device ID.
                var substitute = substituteID
                let status = withUnsafePointer(to: &substitute) { ptr in
                    original(unit, propertyID, scope, element, ptr,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
                }

                os_unfair_lock_lock(&lock)
                deviceRedirectCount += 1
                os_unfair_lock_unlock(&lock)

                logger.info("""
                    Redirected AudioUnit device — \
                    unit=\(String(describing: OpaquePointer(unit))), \
                    scope=\(scope), \
                    original=\(originalDeviceID) -> \(substituteID), \
                    status=\(status)
                    """)

                return status
            }
        }

        // Not a device property or not a tracked unit -- pass through.
        return original(unit, propertyID, scope, element, data, dataSize)
    }

    /// Hook for `AudioUnitGetProperty`.
    ///
    /// When queried for `kAudioOutputUnitProperty_CurrentDevice` on a tracked
    /// unit, we report our target device ID instead of whatever VZ set.
    private static let hook_AudioUnitGetProperty:
        @convention(c) (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                        UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>) -> OSStatus =
    { unit, propertyID, scope, element, data, dataSize in
        guard let original = orig_AudioUnitGetProperty else {
            return OSStatus(kAudioUnitErr_FailedInitialization)
        }

        // Let the original call execute first.
        let status = original(unit, propertyID, scope, element, data, dataSize)

        // If it succeeded and this is a device query on a tracked unit,
        // replace the returned device ID with our target.
        if status == noErr,
           propertyID == kAudioOutputUnitProperty_CurrentDevice,
           let data = data,
           dataSize.pointee >= UInt32(MemoryLayout<AudioDeviceID>.size) {

            os_unfair_lock_lock(&lock)
            let isTrackedUnit = trackedUnits.contains(OpaquePointer(unit))
            let outDevice = targetOutputDeviceID
            let inDevice = targetInputDeviceID
            os_unfair_lock_unlock(&lock)

            if isTrackedUnit {
                let substituteID: AudioDeviceID
                if scope == kAudioUnitScope_Input && inDevice != 0 {
                    substituteID = inDevice
                } else if outDevice != 0 {
                    substituteID = outDevice
                } else {
                    return status
                }

                data.assumingMemoryBound(to: AudioDeviceID.self).pointee = substituteID
            }
        }

        return status
    }
}

// MARK: - InterceptionError

/// Errors that can occur during audio hook installation or removal.
public enum InterceptionError: Error, Sendable, CustomStringConvertible {
    /// Hooks are already installed. Call `uninstall()` first.
    case alreadyInstalled

    /// The fishhook `rebind_symbols` call failed.
    case rebindFailed(code: Int)

    /// The target device ID is invalid (0 or unknown).
    case invalidDeviceID(AudioDeviceID)

    public var description: String {
        switch self {
        case .alreadyInstalled:
            return "Audio interception hooks are already installed"
        case .rebindFailed(let code):
            return "rebind_symbols failed with code \(code)"
        case .invalidDeviceID(let id):
            return "Invalid audio device ID: \(id)"
        }
    }
}
