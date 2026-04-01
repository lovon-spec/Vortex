// AudioOutputUnit.swift — Per-VM audio output routing via CoreAudio HAL.
// VortexAudio
//
// Creates a kAudioUnitSubType_HALOutput AudioUnit routed to a specific host
// output device (NOT the system default). A render callback pulls PCM data
// from an AudioRingBuffer that the device emulation layer writes into.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - AudioOutputUnit

/// Manages a HAL output AudioUnit that plays audio through a specific host
/// device. Each VM gets its own `AudioOutputUnit` instance pointed at whatever
/// output device the user has configured.
///
/// The render callback pulls interleaved Float32 PCM from the attached
/// `AudioRingBuffer`. If the ring buffer underruns, silence is output.
public final class AudioOutputUnit: @unchecked Sendable {

    // MARK: - Properties

    /// The CoreAudio device ID this unit is routed to.
    public private(set) var deviceID: AudioDeviceID

    /// The ring buffer that the VM writes audio data into.
    /// The render callback reads from this buffer.
    public let ringBuffer: AudioRingBuffer

    /// The audio stream format used by this output unit.
    public private(set) var streamFormat: AudioStreamBasicDescription

    /// Whether the unit is currently playing.
    public private(set) var isRunning: Bool = false

    /// The underlying AudioUnit instance.
    private var audioUnit: AudioUnit?

    /// Optional latency collector for measuring pipeline latency.
    ///
    /// When set and enabled, the render callback records timing samples
    /// by comparing the current `mach_absolute_time()` against the
    /// timestamp stored by the bridge when PCM data was written.
    ///
    /// - Important: The collector must be set BEFORE calling `start()`.
    ///   Changing it while running has no effect until the next start cycle.
    public var latencyCollector: LatencyCollector?

    // MARK: - Init

    /// Creates an output unit routed to a specific device.
    ///
    /// - Parameters:
    ///   - deviceID: The `AudioDeviceID` to play through (must be an output device).
    ///   - sampleRate: Sample rate in Hz (e.g. 44100, 48000).
    ///   - channels: Number of channels (default 2 for stereo).
    ///   - bitDepth: Bit depth — use 16 for Int16 or 32 for Float32 (default 32).
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

        try createAndConfigureUnit()
    }

    deinit {
        stop()
        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    // MARK: - Lifecycle

    /// Initialize and start the output unit. Audio will begin playing.
    public func start() throws {
        guard !isRunning, let unit = audioUnit else { return }

        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "AudioOutputUnitStart")
        }
        isRunning = true
    }

    /// Stop the output unit. Audio ceases immediately.
    public func stop() {
        guard isRunning, let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    /// Switch this output unit to a different device while preserving the
    /// ring buffer and format. Stops playback, reconfigures, and optionally
    /// restarts.
    ///
    /// - Parameters:
    ///   - newDeviceID: The new device to route to.
    ///   - restart: If `true`, automatically restart playback after switching.
    public func switchDevice(to newDeviceID: AudioDeviceID, restart: Bool = true) throws {
        let wasRunning = isRunning
        stop()

        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }

        self.deviceID = newDeviceID
        try createAndConfigureUnit()

        if wasRunning && restart {
            try start()
        }
    }

    /// Reconfigure the stream format. Stops the unit if running.
    public func reconfigure(
        sampleRate: Float64,
        channels: UInt32,
        bitDepth: UInt32
    ) throws {
        let wasRunning = isRunning
        stop()

        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }

        self.streamFormat = AudioOutputUnit.makeStreamFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth
        )

        try createAndConfigureUnit()

        if wasRunning {
            try start()
        }
    }

    // MARK: - Private: setup

    private func createAndConfigureUnit() throws {
        // 1. Find the HALOutput audio component.
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioDeviceError.audioUnitError(
                OSStatus(kAudioUnitErr_InvalidOfflineRender),
                "HALOutput component not found"
            )
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit = unit else {
            throw AudioDeviceError.audioUnitError(status, "AudioComponentInstanceNew")
        }
        self.audioUnit = unit

        // 2. Set the output device (NOT the system default).
        var devID = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status,
                "Set CurrentDevice to \(deviceID)")
        }

        // 3. Set the stream format on the input scope of element 0 (output bus).
        //    This tells the AudioUnit what format our render callback provides.
        var format = streamFormat
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,  // element 0 = output bus
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "Set stream format")
        }

        // 4. Install the render callback.
        //    The refCon (user data) is a pointer to this AudioOutputUnit instance.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: refCon
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "Set render callback")
        }

        // 5. Initialize the unit.
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "AudioUnitInitialize")
        }
    }

    // MARK: - Format helper

    /// Build an `AudioStreamBasicDescription` for interleaved PCM.
    internal static func makeStreamFormat(
        sampleRate: Float64,
        channels: UInt32,
        bitDepth: UInt32
    ) -> AudioStreamBasicDescription {
        let isFloat = (bitDepth == 32)
        let bytesPerSample = bitDepth / 8
        let bytesPerFrame = bytesPerSample * channels

        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        if isFloat {
            flags |= kAudioFormatFlagIsFloat
        } else {
            flags |= kAudioFormatFlagIsSignedInteger
        }

        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitDepth,
            mReserved: 0
        )
    }
}

// MARK: - Render callback (C function)

/// The CoreAudio render callback. Called on the real-time audio thread.
/// Pulls data from the ring buffer. If not enough data is available,
/// outputs silence for the missing frames.
///
/// When a `LatencyCollector` is attached and enabled, also records a
/// latency sample: the delta between `mach_absolute_time()` now and the
/// timestamp the bridge stored when it last wrote PCM into the ring buffer.
/// This gives the one-way output latency (guest PCM arrival -> host render).
private func outputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData = ioData else { return noErr }

    let outputUnit = Unmanaged<AudioOutputUnit>.fromOpaque(inRefCon)
        .takeUnretainedValue()
    let ringBuffer = outputUnit.ringBuffer
    let frameCount = Int(inNumberFrames)

    // Latency instrumentation: capture time before reading from ring buffer.
    // All operations here are RT-safe (mach_absolute_time is vDSO, atomics
    // are lock-free, recordSample does only pointer writes).
    let collector = outputUnit.latencyCollector
    let renderTime: UInt64
    if let collector, collector.isEnabled {
        renderTime = mach_absolute_time()
    } else {
        renderTime = 0
    }

    // Get the buffer from the AudioBufferList.
    let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
    guard let firstBuffer = bufferList.first,
          let dataPtr = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    let totalSamples = frameCount * ringBuffer.channelCount
    let dest = UnsafeMutableBufferPointer(start: dataPtr, count: totalSamples)

    // Snapshot buffer depth BEFORE reading (how many frames were waiting).
    let bufferDepth = ringBuffer.framesAvailableForRead

    let framesRead = ringBuffer.read(dest, frameCount: frameCount)

    // Zero-fill any remaining frames (underrun -> silence).
    let samplesRead = framesRead * ringBuffer.channelCount
    if samplesRead < totalSamples {
        dest.baseAddress!.advanced(by: samplesRead)
            .initialize(repeating: 0.0, count: totalSamples - samplesRead)
    }

    // Record latency sample if instrumentation is active and we read real data.
    if let collector, renderTime != 0, framesRead > 0 {
        let writeTime = collector.loadWriteTimestamp()
        if writeTime != 0 && renderTime > writeTime {
            let delta = renderTime - writeTime
            collector.recordSample(
                ticks: delta,
                bufferFrames: Int32(clamping: bufferDepth)
            )
        }
    }

    return noErr
}
