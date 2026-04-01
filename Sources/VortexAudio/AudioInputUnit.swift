// AudioInputUnit.swift — Per-VM audio input capture via AudioQueue.
// VortexAudio
//
// Uses AudioQueue Services for audio input capture from a specific host device.
// This replaces two prior approaches that failed:
//   1. AUHAL AudioUnit: AudioUnitRender returned -10863
//      (kAudioUnitErr_CannotDoInCurrentContext) on every call.
//   2. AudioDeviceCreateIOProcID: Captured only silence from BlackHole loopback
//      devices — the IOProc never received loopback audio.
//
// AudioQueue is a higher-level API that handles format negotiation and sample
// rate conversion automatically. It uses device UID (CFString) for device
// selection rather than AudioDeviceID.

import AudioToolbox
import CoreAudio
import Foundation
import VortexCore

// MARK: - AudioInputUnit

/// Manages audio input (capture) from a specific host CoreAudio device using
/// AudioQueue Services. Each VM gets its own `AudioInputUnit` pointed at
/// whichever microphone or virtual input the user has configured.
///
/// The AudioQueue input callback pushes captured interleaved Float32 PCM into
/// the attached `AudioRingBuffer`. If the ring buffer overflows, the oldest
/// samples that have not been consumed are effectively lost as new data
/// overwrites the write frontier (the callback drops frames it cannot write).
///
/// ## Threading
/// - `init`, `start`, `stop`, `switchDevice`, `reconfigure` must be called
///   from the main thread or a serial queue.
/// - The AudioQueue input callback runs on an internal AudioQueue thread. It
///   performs only memcpy and atomic operations — no allocations, locks, or
///   syscalls.
public final class AudioInputUnit: @unchecked Sendable {

    // MARK: - Constants

    /// Number of AudioQueue buffers to allocate (standard triple-buffering).
    private static let bufferCount = 3

    /// Duration of each AudioQueue buffer in seconds. This controls the
    /// callback frequency — shorter buffers mean lower latency but more CPU.
    private static let bufferDurationSeconds: Double = 0.01  // 10ms

    // MARK: - Properties

    /// The CoreAudio device ID this unit captures from.
    public private(set) var deviceID: AudioDeviceID

    /// The device UID string. AudioQueue uses this (not AudioDeviceID) for
    /// device selection via `kAudioQueueProperty_CurrentDevice`.
    private var deviceUID: String

    /// The ring buffer that captured audio is written into.
    /// The device emulation layer reads from this buffer.
    public let ringBuffer: AudioRingBuffer

    /// The target audio stream format (what callers expect).
    public private(set) var streamFormat: AudioStreamBasicDescription

    /// Whether the unit is currently capturing.
    public private(set) var isRunning: Bool = false

    /// The AudioQueue instance, or `nil` if not set up.
    private var audioQueue: AudioQueueRef?

    /// Pre-allocated AudioQueue buffers for triple-buffering.
    private var audioQueueBuffers: [AudioQueueBufferRef?] = []

    // MARK: - Init

    /// Creates an input unit that captures from a specific device.
    ///
    /// - Parameters:
    ///   - deviceID: The `AudioDeviceID` to capture from (must be an input device).
    ///   - sampleRate: Sample rate in Hz (e.g. 44100, 48000).
    ///   - channels: Number of channels (default 2 for stereo).
    ///   - bitDepth: Bit depth — 16 for Int16 or 32 for Float32 (default 32).
    ///   - bufferFrames: Ring buffer capacity in frames (default ~100ms at sample rate).
    public init(
        deviceID: AudioDeviceID,
        sampleRate: Float64 = 48000,
        channels: UInt32 = 2,
        bitDepth: UInt32 = 32,
        bufferFrames: Int? = nil
    ) throws {
        self.deviceID = deviceID

        // Resolve AudioDeviceID to device UID string.
        self.deviceUID = try AudioInputUnit.resolveDeviceUID(deviceID: deviceID)

        let frames = bufferFrames ?? Int(sampleRate / 10) // ~100ms default
        self.ringBuffer = AudioRingBuffer(frameCapacity: frames,
                                          channelCount: Int(channels))

        self.streamFormat = AudioOutputUnit.makeStreamFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )

        try setupAudioQueue()
    }

    deinit {
        stop()
        teardownAudioQueue()
    }

    // MARK: - Lifecycle

    /// Start capturing audio from the input device.
    public func start() throws {
        guard !isRunning, audioQueue != nil else { return }

        let status = AudioQueueStart(audioQueue!, nil)
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status,
                "AudioQueueStart for input device \(deviceID) (\(deviceUID))")
        }
        isRunning = true
        VortexLog.audio.info("AudioInputUnit started capture on device \(self.deviceID) (UID: \(self.deviceUID))")
    }

    /// Stop capturing audio.
    public func stop() {
        guard isRunning, let queue = audioQueue else { return }
        AudioQueueStop(queue, true) // synchronous stop
        isRunning = false
        VortexLog.audio.info("AudioInputUnit stopped capture on device \(self.deviceID)")
    }

    /// Switch this input unit to a different device.
    ///
    /// - Parameters:
    ///   - newDeviceID: The new input device to capture from.
    ///   - restart: If `true`, automatically restart capture after switching.
    public func switchDevice(to newDeviceID: AudioDeviceID, restart: Bool = true) throws {
        let wasRunning = isRunning
        stop()
        teardownAudioQueue()

        self.deviceID = newDeviceID
        self.deviceUID = try AudioInputUnit.resolveDeviceUID(deviceID: newDeviceID)
        try setupAudioQueue()

        if wasRunning && restart {
            try start()
        }
    }

    /// Reconfigure the stream format. Stops capture if running.
    public func reconfigure(
        sampleRate: Float64,
        channels: UInt32,
        bitDepth: UInt32
    ) throws {
        let wasRunning = isRunning
        stop()
        teardownAudioQueue()

        self.streamFormat = AudioOutputUnit.makeStreamFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )

        try setupAudioQueue()

        if wasRunning {
            try start()
        }
    }

    // MARK: - Private: Device UID Resolution

    /// Resolve an `AudioDeviceID` to its UID string.
    ///
    /// AudioQueue uses device UID (a `CFString`) for device selection via
    /// `kAudioQueueProperty_CurrentDevice`, not `AudioDeviceID`.
    private static func resolveDeviceUID(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &uid
        )
        guard status == noErr, let cfString = uid else {
            throw AudioDeviceError.coreAudioError(status,
                "Failed to resolve UID for AudioDeviceID \(deviceID)")
        }
        return cfString.takeRetainedValue() as String
    }

    // MARK: - Private: Setup / Teardown

    /// Create the AudioQueue, set the target device, allocate buffers, and
    /// enqueue them so the queue is ready to start.
    private func setupAudioQueue() throws {
        // 1. Create input AudioQueue with our target format.
        //    The callback receives captured PCM in the requested format —
        //    AudioQueue handles any necessary sample rate / format conversion.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var queue: AudioQueueRef?

        var format = streamFormat
        let status = AudioQueueNewInput(
            &format,
            audioQueueInputCallback,
            refCon,
            nil,    // run loop — nil uses internal thread
            nil,    // run loop mode
            0,      // flags (reserved)
            &queue
        )
        guard status == noErr, let createdQueue = queue else {
            throw AudioDeviceError.audioUnitError(status,
                "AudioQueueNewInput for device \(deviceID)")
        }
        self.audioQueue = createdQueue

        // 2. Set the target device via its UID string.
        //    This directs the AudioQueue to capture from our specific device,
        //    not the system default input.
        //    kAudioQueueProperty_CurrentDevice expects a pointer to a CFStringRef.
        let cfUID: CFString = deviceUID as CFString
        let deviceStatus = withUnsafePointer(to: cfUID) { ptr in
            AudioQueueSetProperty(
                createdQueue,
                kAudioQueueProperty_CurrentDevice,
                ptr,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
        guard deviceStatus == noErr else {
            AudioQueueDispose(createdQueue, true)
            self.audioQueue = nil
            throw AudioDeviceError.audioUnitError(deviceStatus,
                "AudioQueueSetProperty(CurrentDevice) for UID '\(deviceUID)'")
        }

        VortexLog.audio.info("AudioInputUnit AudioQueue created for device \(self.deviceID) (UID: \(self.deviceUID)), format: \(AudioFormatConverter.formatDescription(self.streamFormat))")

        // 3. Calculate buffer size for the desired duration.
        //    Each buffer holds `bufferDurationSeconds` worth of audio.
        let bytesPerFrame = streamFormat.mBytesPerFrame
        let framesPerBuffer = UInt32(streamFormat.mSampleRate * Self.bufferDurationSeconds)
        let bufferByteSize = framesPerBuffer * bytesPerFrame

        // 4. Allocate and enqueue triple buffers.
        audioQueueBuffers = []
        audioQueueBuffers.reserveCapacity(Self.bufferCount)

        for i in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(
                createdQueue,
                bufferByteSize,
                &buffer
            )
            guard allocStatus == noErr, buffer != nil else {
                // Clean up already-allocated buffers.
                teardownAudioQueue()
                throw AudioDeviceError.audioUnitError(allocStatus,
                    "AudioQueueAllocateBuffer[\(i)] for device \(deviceID)")
            }
            audioQueueBuffers.append(buffer)

            let enqueueStatus = AudioQueueEnqueueBuffer(
                createdQueue,
                buffer!,
                0,
                nil
            )
            guard enqueueStatus == noErr else {
                teardownAudioQueue()
                throw AudioDeviceError.audioUnitError(enqueueStatus,
                    "AudioQueueEnqueueBuffer[\(i)] for device \(deviceID)")
            }
        }

        VortexLog.audio.info("AudioInputUnit \(Self.bufferCount) buffers allocated (\(bufferByteSize) bytes each, \(framesPerBuffer) frames)")
    }

    /// Dispose of the AudioQueue and release all buffers.
    private func teardownAudioQueue() {
        if let queue = audioQueue {
            // AudioQueueDispose also frees all associated buffers.
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
        audioQueueBuffers = []
    }

    // MARK: - Internal: Callback Access

    /// Called from the C callback function to process a captured buffer.
    /// Writes captured PCM into the ring buffer and re-enqueues the buffer.
    ///
    /// - Important: This runs on the AudioQueue's internal thread. Keep it
    ///   lightweight — only memcpy and atomics. No allocations or locks.
    fileprivate func handleInputBuffer(
        _ queue: AudioQueueRef,
        _ buffer: AudioQueueBufferRef,
        _ startTime: UnsafePointer<AudioTimeStamp>,
        _ numPackets: UInt32
    ) {
        let dataSize = Int(buffer.pointee.mAudioDataByteSize)
        guard dataSize > 0 else {
            // Re-enqueue even if empty to keep the queue running.
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }

        let channelCount = Int(streamFormat.mChannelsPerFrame)
        let bytesPerSample = Int(streamFormat.mBitsPerChannel / 8)
        let sampleCount = dataSize / bytesPerSample
        let frameCount = sampleCount / max(channelCount, 1)

        // The AudioQueue was created with Float32 interleaved format, so the
        // buffer data is already in the correct format for the ring buffer.
        let floatPtr = buffer.pointee.mAudioData
            .assumingMemoryBound(to: Float.self)
        let source = UnsafeBufferPointer(start: floatPtr, count: sampleCount)
        _ = ringBuffer.write(source, frameCount: frameCount)

        // Re-enqueue the buffer so the AudioQueue can refill it.
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}

// MARK: - AudioQueue Input Callback (C function)

/// The AudioQueue input callback. Called on the AudioQueue's internal thread
/// when a buffer of captured audio is available.
///
/// - Important: This runs on a real-time-priority thread managed by AudioQueue.
///   Keep it lightweight — only memcpy and atomics. No allocations, locks, or
///   syscalls beyond the re-enqueue call.
private func audioQueueInputCallback(
    _ userData: UnsafeMutableRawPointer?,
    _ queue: AudioQueueRef,
    _ buffer: AudioQueueBufferRef,
    _ startTime: UnsafePointer<AudioTimeStamp>,
    _ numPackets: UInt32,
    _ packetDescs: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData = userData else { return }

    let inputUnit = Unmanaged<AudioInputUnit>.fromOpaque(userData)
        .takeUnretainedValue()

    inputUnit.handleInputBuffer(queue, buffer, startTime, numPackets)
}
