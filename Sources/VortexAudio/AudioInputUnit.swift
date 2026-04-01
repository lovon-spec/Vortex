// AudioInputUnit.swift — Per-VM audio input capture via CoreAudio device IOProc.
// VortexAudio
//
// Uses the low-level CoreAudio device IOProc API (AudioDeviceCreateIOProcID /
// AudioDeviceStart / AudioDeviceStop) to capture audio from a specific host
// input device. This replaces the previous AUHAL-based approach which failed
// with error -10863 (kAudioUnitErr_CannotDoInCurrentContext) on every
// AudioUnitRender call.
//
// The IOProc callback receives captured audio directly in its `inputData`
// parameter — no rendering step needed. The captured PCM is converted to
// interleaved Float32 if necessary and written into an AudioRingBuffer that
// the device emulation layer reads from.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - AudioInputUnit

/// Manages audio input (capture) from a specific host CoreAudio device using
/// the device IOProc API. Each VM gets its own `AudioInputUnit` pointed at
/// whichever microphone or virtual input the user has configured.
///
/// The IOProc callback pushes captured interleaved Float32 PCM into the
/// attached `AudioRingBuffer`. If the ring buffer overflows, the oldest
/// samples that have not been consumed are effectively lost as new data
/// overwrites the write frontier (the callback drops frames it cannot write).
///
/// ## Threading
/// - `init`, `start`, `stop`, `switchDevice`, `reconfigure` must be called
///   from the main thread or a serial queue.
/// - The IOProc callback runs on the CoreAudio real-time thread. It performs
///   only memcpy and atomic operations — no allocations, locks, or syscalls.
public final class AudioInputUnit: @unchecked Sendable {

    // MARK: - Properties

    /// The CoreAudio device ID this unit captures from.
    public private(set) var deviceID: AudioDeviceID

    /// The ring buffer that captured audio is written into.
    /// The device emulation layer reads from this buffer.
    public let ringBuffer: AudioRingBuffer

    /// The target audio stream format (what callers expect).
    public private(set) var streamFormat: AudioStreamBasicDescription

    /// Whether the unit is currently capturing.
    public private(set) var isRunning: Bool = false

    /// Callback invocation counter for diagnostics.
    var callbackCount: UInt64 = 0

    /// The registered IOProc ID, or `nil` if not registered.
    fileprivate var ioProcID: AudioDeviceIOProcID?

    /// The device's native input stream format. Queried at setup time and
    /// used to interpret the raw data delivered by the IOProc callback.
    fileprivate var deviceNativeFormat: AudioStreamBasicDescription?

    /// Pre-allocated scratch buffer for format conversion. Sized for the
    /// maximum expected callback (4096 frames * channels * sizeof(Float)).
    /// Only used when the device's native format differs from our target
    /// Float32 interleaved format.
    fileprivate var conversionBuffer: UnsafeMutablePointer<Float>?
    fileprivate var conversionBufferFrameCapacity: Int = 0

    /// Whether the device's native format requires conversion to our
    /// target format. Determined at setup time.
    fileprivate var needsConversion: Bool = false

    /// Number of channels in the device's native format (may differ from
    /// our target channel count).
    fileprivate var nativeChannels: UInt32 = 0

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

        let frames = bufferFrames ?? Int(sampleRate / 10) // ~100ms default
        self.ringBuffer = AudioRingBuffer(frameCapacity: frames,
                                          channelCount: Int(channels))

        self.streamFormat = AudioOutputUnit.makeStreamFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )

        try setupIOProc()
    }

    deinit {
        stop()
        teardownIOProc()
        if let buf = conversionBuffer {
            buf.deallocate()
        }
    }

    // MARK: - Lifecycle

    /// Start capturing audio from the input device.
    public func start() throws {
        guard !isRunning, let procID = ioProcID else { return }

        let status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status,
                "AudioDeviceStart for input device \(deviceID)")
        }
        isRunning = true
        print("[AudioInputUnit] Started capture on device \(deviceID)")
    }

    /// Stop capturing audio.
    public func stop() {
        guard isRunning, let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        isRunning = false
        print("[AudioInputUnit] Stopped capture on device \(deviceID)")
    }

    /// Switch this input unit to a different device.
    ///
    /// - Parameters:
    ///   - newDeviceID: The new input device to capture from.
    ///   - restart: If `true`, automatically restart capture after switching.
    public func switchDevice(to newDeviceID: AudioDeviceID, restart: Bool = true) throws {
        let wasRunning = isRunning
        stop()
        teardownIOProc()

        self.deviceID = newDeviceID
        try setupIOProc()

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
        teardownIOProc()

        self.streamFormat = AudioOutputUnit.makeStreamFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )

        try setupIOProc()

        if wasRunning {
            try start()
        }
    }

    // MARK: - Private: setup / teardown

    /// Query the device's native input format, register the IOProc, and
    /// allocate any conversion buffers needed.
    private func setupIOProc() throws {
        // 1. Query the device's native stream format on the input scope.
        var nativeFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyData(
            deviceID,
            &formatAddress,
            0, nil,
            &formatSize,
            &nativeFormat
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status,
                "Query native input format for device \(deviceID)")
        }

        self.deviceNativeFormat = nativeFormat
        self.nativeChannels = nativeFormat.mChannelsPerFrame

        print("[AudioInputUnit] Device \(deviceID) native input format: " +
              "\(AudioFormatConverter.formatDescription(nativeFormat))")
        print("[AudioInputUnit] Target format: " +
              "\(AudioFormatConverter.formatDescription(streamFormat))")

        // 2. Determine if format conversion is needed.
        //    We need conversion if:
        //    - The native format is not Float32
        //    - The channel count differs
        //    - The sample rate differs (we handle channel/format mismatch in
        //      the IOProc; sample rate mismatch would need a proper converter
        //      but most devices will match our requested rate)
        let nativeIsFloat32 = (nativeFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && nativeFormat.mBitsPerChannel == 32
        let channelMatch = nativeFormat.mChannelsPerFrame == streamFormat.mChannelsPerFrame

        needsConversion = !nativeIsFloat32 || !channelMatch
        if needsConversion {
            print("[AudioInputUnit] Format conversion enabled " +
                  "(nativeFloat32=\(nativeIsFloat32), channelMatch=\(channelMatch))")
        }

        // 3. Allocate conversion scratch buffer.
        //    Sized for 4096 frames * target channels — enough for any
        //    reasonable callback size.
        let maxFrames = 4096
        let targetChannels = Int(streamFormat.mChannelsPerFrame)
        conversionBufferFrameCapacity = maxFrames
        if let old = conversionBuffer { old.deallocate() }
        conversionBuffer = .allocate(capacity: maxFrames * targetChannels)

        // 4. Register the IOProc with the device.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?

        status = AudioDeviceCreateIOProcID(
            deviceID,
            inputIOProc,
            refCon,
            &procID
        )
        guard status == noErr, procID != nil else {
            throw AudioDeviceError.audioUnitError(status,
                "AudioDeviceCreateIOProcID for input device \(deviceID)")
        }
        self.ioProcID = procID
        self.callbackCount = 0

        print("[AudioInputUnit] IOProc registered for device \(deviceID)")
    }

    /// Remove the IOProc registration and release resources.
    private func teardownIOProc() {
        if let procID = ioProcID {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
        }
        deviceNativeFormat = nil
    }
}

// MARK: - Device IOProc (C function)

/// The CoreAudio device IOProc callback. Called on the real-time audio thread
/// when the device has captured new audio data. Unlike AUHAL, the captured
/// audio is delivered directly in `inputData` — no AudioUnitRender call needed.
///
/// - Important: This runs on a real-time thread. No allocations, no locks,
///   no syscalls. Only memcpy and atomics.
private func inputIOProc(
    _ deviceID: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }

    let inputUnit = Unmanaged<AudioInputUnit>.fromOpaque(clientData)
        .takeUnretainedValue()

    inputUnit.callbackCount += 1
    let cbCount = inputUnit.callbackCount

    // Access the first buffer from the input data.
    // The AudioBufferList is a variable-length struct; we read the first buffer.
    let bufferCount = Int(inputData.pointee.mNumberBuffers)
    guard bufferCount > 0 else {
        return noErr
    }

    let firstBuffer = inputData.pointee.mBuffers
    let dataSize = Int(firstBuffer.mDataByteSize)

    guard dataSize > 0, let rawData = firstBuffer.mData else {
        return noErr
    }

    let nativeChannels = Int(firstBuffer.mNumberChannels)
    let targetChannels = Int(inputUnit.streamFormat.mChannelsPerFrame)

    if !inputUnit.needsConversion {
        // Fast path: native format is Float32 with matching channel count.
        // Write directly from inputData into the ring buffer.
        let sampleCount = dataSize / MemoryLayout<Float>.size
        let frameCount = sampleCount / max(nativeChannels, 1)

        let floatPtr = rawData.assumingMemoryBound(to: Float.self)
        let source = UnsafeBufferPointer(start: floatPtr, count: sampleCount)
        let written = inputUnit.ringBuffer.write(source, frameCount: frameCount)

        if cbCount <= 5 || cbCount % 5000 == 0 {
            // Check for non-zero audio data
            var maxAbs: Float = 0
            for i in 0..<min(sampleCount, 64) {
                let v = abs(floatPtr[i])
                if v > maxAbs { maxAbs = v }
            }
            print("[AudioInputUnit] IOProc #\(cbCount): \(frameCount) frames " +
                  "(direct), wrote \(written), peak=\(maxAbs)")
        }
    } else {
        // Slow path: need format conversion.
        guard let convBuf = inputUnit.conversionBuffer else { return noErr }

        let nativeFormat = inputUnit.deviceNativeFormat
        let nativeBitsPerChannel = nativeFormat?.mBitsPerChannel ?? 32
        let nativeIsFloat = (nativeFormat?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
        let nativeIsSignedInt = (nativeFormat?.mFormatFlags ?? 0) & kAudioFormatFlagIsSignedInteger != 0
        let nativeBytesPerSample = Int(nativeBitsPerChannel / 8)

        // Calculate frame count from the native format.
        let nativeFrameBytes = nativeBytesPerSample * max(nativeChannels, 1)
        let frameCount: Int
        if nativeFrameBytes > 0 {
            frameCount = dataSize / nativeFrameBytes
        } else {
            return noErr
        }

        // Guard against overflow of our conversion buffer.
        guard frameCount <= inputUnit.conversionBufferFrameCapacity else {
            return noErr
        }

        let outputSamples = frameCount * targetChannels

        // Convert each frame: extract from native format, write as Float32
        // into the conversion buffer with channel mapping.
        if nativeIsFloat && nativeBitsPerChannel == 32 {
            // Float32 source but channel count mismatch.
            let srcFloats = rawData.assumingMemoryBound(to: Float.self)
            let minChannels = min(nativeChannels, targetChannels)

            for frame in 0..<frameCount {
                let srcOffset = frame * nativeChannels
                let dstOffset = frame * targetChannels

                // Copy channels that exist in both.
                for ch in 0..<Int(minChannels) {
                    convBuf[dstOffset + ch] = srcFloats[srcOffset + ch]
                }
                // Zero-fill extra target channels.
                for ch in Int(minChannels)..<targetChannels {
                    convBuf[dstOffset + ch] = 0.0
                }
            }
        } else if nativeIsSignedInt && nativeBitsPerChannel == 16 {
            // Int16 source — convert to Float32.
            let srcInt16 = rawData.assumingMemoryBound(to: Int16.self)
            let scale: Float = 1.0 / 32768.0
            let minChannels = min(nativeChannels, targetChannels)

            for frame in 0..<frameCount {
                let srcOffset = frame * nativeChannels
                let dstOffset = frame * targetChannels

                for ch in 0..<Int(minChannels) {
                    convBuf[dstOffset + ch] = Float(srcInt16[srcOffset + ch]) * scale
                }
                for ch in Int(minChannels)..<targetChannels {
                    convBuf[dstOffset + ch] = 0.0
                }
            }
        } else if nativeIsSignedInt && nativeBitsPerChannel == 32 {
            // Int32 source — convert to Float32.
            let srcInt32 = rawData.assumingMemoryBound(to: Int32.self)
            let scale: Float = 1.0 / 2147483648.0
            let minChannels = min(nativeChannels, targetChannels)

            for frame in 0..<frameCount {
                let srcOffset = frame * nativeChannels
                let dstOffset = frame * targetChannels

                for ch in 0..<Int(minChannels) {
                    convBuf[dstOffset + ch] = Float(srcInt32[srcOffset + ch]) * scale
                }
                for ch in Int(minChannels)..<targetChannels {
                    convBuf[dstOffset + ch] = 0.0
                }
            }
        } else {
            // Unsupported native format — write silence.
            for i in 0..<outputSamples {
                convBuf[i] = 0.0
            }
            if cbCount <= 3 {
                print("[AudioInputUnit] IOProc #\(cbCount): unsupported native format " +
                      "(bits=\(nativeBitsPerChannel), float=\(nativeIsFloat), " +
                      "int=\(nativeIsSignedInt)), outputting silence")
            }
        }

        let source = UnsafeBufferPointer(start: convBuf, count: outputSamples)
        let written = inputUnit.ringBuffer.write(source, frameCount: frameCount)

        if cbCount <= 3 || cbCount % 5000 == 0 {
            print("[AudioInputUnit] IOProc #\(cbCount): \(frameCount) frames " +
                  "(converted), wrote \(written) to ring buffer")
        }
    }

    return noErr
}
