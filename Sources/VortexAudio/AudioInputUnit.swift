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
    /// This is always at the pipeline's target sample rate.
    public private(set) var streamFormat: AudioStreamBasicDescription

    /// The format the AudioQueue actually captures in. When the device's
    /// native rate differs from the target, this will be at the device rate
    /// and `resampleConverter` will convert to `streamFormat`.
    private var captureFormat: AudioStreamBasicDescription

    /// Whether the unit is currently capturing.
    public private(set) var isRunning: Bool = false

    /// The AudioQueue instance, or `nil` if not set up.
    private var audioQueue: AudioQueueRef?

    /// Pre-allocated AudioQueue buffers for triple-buffering.
    private var audioQueueBuffers: [AudioQueueBufferRef?] = []

    // MARK: - Sample rate conversion

    /// Whether captured audio needs resampling before being written to the
    /// ring buffer (device native rate differs from pipeline target rate).
    private var needsResample: Bool = false

    /// Converter for sample rate conversion when `needsResample` is `true`.
    /// Created at setup time with the capture format as source and
    /// `streamFormat` as destination.
    private var resampleConverter: AudioFormatConverter?

    /// Pre-allocated buffer for holding converted samples. Sized at setup
    /// time to hold a full converted buffer's worth of frames. This avoids
    /// allocations in the AudioQueue callback.
    private var conversionBuffer: UnsafeMutableBufferPointer<Float>?

    /// The number of frames `conversionBuffer` can hold.
    private var conversionBufferFrameCapacity: Int = 0

    // MARK: - Init

    /// Creates an input unit that captures from a specific device.
    ///
    /// - Parameters:
    ///   - deviceID: The `AudioDeviceID` to capture from (must be an input device).
    ///   - sampleRate: Target sample rate in Hz (e.g. 48000). This is the rate
    ///     that downstream consumers (the ring buffer, the VM) expect.
    ///   - channels: Number of channels (default 2 for stereo).
    ///   - bitDepth: Bit depth — 16 for Int16 or 32 for Float32 (default 32).
    ///   - bufferFrames: Ring buffer capacity in frames (default ~100ms at sample rate).
    ///   - deviceNativeSampleRate: The actual sample rate the device is running
    ///     at. When this differs from `sampleRate`, the AudioQueue will capture
    ///     at the device's native rate and a converter will resample to the
    ///     target rate. Pass `nil` to assume the device runs at `sampleRate`.
    public init(
        deviceID: AudioDeviceID,
        sampleRate: Float64 = 48000,
        channels: UInt32 = 2,
        bitDepth: UInt32 = 32,
        bufferFrames: Int? = nil,
        deviceNativeSampleRate: Float64? = nil
    ) throws {
        self.deviceID = deviceID

        // Resolve AudioDeviceID to device UID string.
        self.deviceUID = try AudioInputUnit.resolveDeviceUID(deviceID: deviceID)

        let frames = bufferFrames ?? Int(sampleRate / 10) // ~100ms default
        self.ringBuffer = AudioRingBuffer(frameCapacity: frames,
                                          channelCount: Int(channels))

        // The target format is always at the pipeline's requested sample rate.
        self.streamFormat = AudioOutputUnit.makeStreamFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )

        // Determine whether we need to capture at a different rate than target.
        let deviceRate = deviceNativeSampleRate ?? sampleRate
        let rateMismatch = abs(deviceRate - sampleRate) >= 1.0

        if rateMismatch {
            // Capture at the device's native rate; we will resample in the callback.
            self.captureFormat = AudioOutputUnit.makeStreamFormat(
                sampleRate: deviceRate,
                channels: channels,
                bitDepth: bitDepth
            )
            self.needsResample = true
            VortexLog.audio.info(
                "AudioInputUnit: rate mismatch detected — device \(deviceID) at \(deviceRate) Hz, target \(sampleRate) Hz; resampling enabled"
            )
        } else {
            self.captureFormat = self.streamFormat
            self.needsResample = false
        }

        try setupAudioQueue()
    }

    deinit {
        stop()
        teardownAudioQueue()
        deallocateConversionBuffer()
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
    ///
    /// When `needsResample` is `true`, the AudioQueue is created at the
    /// device's native sample rate (`captureFormat`) rather than the
    /// pipeline's target rate (`streamFormat`). An `AudioFormatConverter`
    /// is created to resample captured audio, and a pre-allocated conversion
    /// buffer is sized to hold the converted output.
    private func setupAudioQueue() throws {
        // 1. Create input AudioQueue at the capture format.
        //    When rates match, captureFormat == streamFormat. When they differ,
        //    captureFormat is at the device's native rate and we resample in the
        //    callback before writing to the ring buffer.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var queue: AudioQueueRef?

        var format = captureFormat
        let status = AudioQueueNewInput(
            &format,
            audioQueueInputCallback,
            refCon,
            nil,    // run loop -- nil uses internal thread
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

        VortexLog.audio.info(
            "AudioInputUnit AudioQueue created for device \(self.deviceID) (UID: \(self.deviceUID)), capture: \(AudioFormatConverter.formatDescription(self.captureFormat)), target: \(AudioFormatConverter.formatDescription(self.streamFormat))"
        )

        // 3. Set up the resampling converter and pre-allocate the conversion
        //    buffer if the capture rate differs from the target rate.
        if needsResample {
            resampleConverter = try AudioFormatConverter(
                from: captureFormat,
                to: streamFormat
            )
            VortexLog.audio.info(
                "AudioInputUnit resample converter created: \(AudioFormatConverter.formatDescription(self.captureFormat)) -> \(AudioFormatConverter.formatDescription(self.streamFormat))"
            )

            // Pre-allocate a conversion buffer large enough for one AudioQueue
            // buffer's worth of converted output. The ratio of output-to-input
            // frames equals (targetRate / captureRate). Add a small margin.
            let captureFramesPerBuffer = Int(captureFormat.mSampleRate * Self.bufferDurationSeconds)
            let ratio = streamFormat.mSampleRate / captureFormat.mSampleRate
            let outputFrames = Int(ceil(Double(captureFramesPerBuffer) * ratio)) + 2
            let outputSamples = outputFrames * Int(streamFormat.mChannelsPerFrame)
            allocateConversionBuffer(sampleCapacity: outputSamples, frameCapacity: outputFrames)
        } else {
            resampleConverter = nil
            deallocateConversionBuffer()
        }

        // 4. Calculate buffer size for the desired duration.
        //    Each buffer holds `bufferDurationSeconds` worth of audio at the
        //    capture rate (which may differ from the target rate).
        let bytesPerFrame = captureFormat.mBytesPerFrame
        let framesPerBuffer = UInt32(captureFormat.mSampleRate * Self.bufferDurationSeconds)
        let bufferByteSize = framesPerBuffer * bytesPerFrame

        // 5. Allocate and enqueue triple buffers.
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

        VortexLog.audio.info("AudioInputUnit \(Self.bufferCount) buffers allocated (\(bufferByteSize) bytes each, \(framesPerBuffer) frames, resample=\(self.needsResample))")
    }

    /// Dispose of the AudioQueue and release all buffers.
    private func teardownAudioQueue() {
        if let queue = audioQueue {
            // AudioQueueDispose also frees all associated buffers.
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
        audioQueueBuffers = []
        resampleConverter = nil
    }

    /// Allocate the pre-sized conversion buffer used during resampling.
    /// Called once at setup time so the callback never allocates.
    private func allocateConversionBuffer(sampleCapacity: Int, frameCapacity: Int) {
        deallocateConversionBuffer()
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: sampleCapacity)
        ptr.initialize(repeating: 0, count: sampleCapacity)
        conversionBuffer = UnsafeMutableBufferPointer(start: ptr, count: sampleCapacity)
        conversionBufferFrameCapacity = frameCapacity
    }

    /// Free the conversion buffer.
    private func deallocateConversionBuffer() {
        if let buf = conversionBuffer {
            buf.baseAddress?.deinitialize(count: buf.count)
            buf.baseAddress?.deallocate()
            conversionBuffer = nil
            conversionBufferFrameCapacity = 0
        }
    }

    // MARK: - Internal: Callback Access

    /// Called from the C callback function to process a captured buffer.
    /// Writes captured PCM into the ring buffer and re-enqueues the buffer.
    ///
    /// When `needsResample` is `true`, the captured audio is at the device's
    /// native rate and must be converted to the pipeline's target rate before
    /// being written to the ring buffer. The conversion uses a pre-allocated
    /// buffer and `AudioConverterFillComplexBuffer` -- both safe to call on
    /// the AudioQueue thread (which is NOT a real-time CoreAudio thread, so
    /// the converter's internal allocations are acceptable).
    ///
    /// - Important: This runs on the AudioQueue's internal thread. It performs
    ///   memcpy, atomics, and (when resampling) AudioConverter calls. No
    ///   user-level allocations or locks.
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

        let channelCount = Int(captureFormat.mChannelsPerFrame)
        let bytesPerSample = Int(captureFormat.mBitsPerChannel / 8)
        let sampleCount = dataSize / bytesPerSample
        let frameCount = sampleCount / max(channelCount, 1)

        if needsResample, let converter = resampleConverter,
           let convBuf = conversionBuffer {
            // Convert from device native rate to target rate.
            let sourcePtr = buffer.pointee.mAudioData
            do {
                let result = try converter.convert(
                    sourcePtr,
                    sourceFrameCount: UInt32(frameCount)
                )

                let convertedFrames = Int(result.frameCount)
                let convertedSamples = convertedFrames * Int(streamFormat.mChannelsPerFrame)

                // Bounds check against our pre-allocated buffer.
                guard convertedSamples <= convBuf.count,
                      let convBase = convBuf.baseAddress else {
                    // Fallback: drop this buffer rather than crashing.
                    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                    return
                }

                // Copy converted bytes into the Float conversion buffer.
                result.data.withUnsafeBytes { rawBytes in
                    guard let src = rawBytes.baseAddress else { return }
                    let byteCount = min(
                        convertedSamples * MemoryLayout<Float>.size,
                        rawBytes.count
                    )
                    memcpy(convBase, src, byteCount)
                }

                let source = UnsafeBufferPointer(start: convBase, count: convertedSamples)
                _ = ringBuffer.write(source, frameCount: convertedFrames)
            } catch {
                // Conversion failed -- drop this buffer rather than writing
                // garbage or silence. This should be rare.
                VortexLog.audio.error(
                    "AudioInputUnit resample failed: \(error.localizedDescription)"
                )
            }
        } else {
            // No resampling needed -- write captured data directly.
            let floatPtr = buffer.pointee.mAudioData
                .assumingMemoryBound(to: Float.self)
            let source = UnsafeBufferPointer(start: floatPtr, count: sampleCount)
            _ = ringBuffer.write(source, frameCount: frameCount)
        }

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
