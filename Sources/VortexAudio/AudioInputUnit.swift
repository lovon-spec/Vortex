// AudioInputUnit.swift — Per-VM audio input capture via CoreAudio HAL.
// VortexAudio
//
// Creates a kAudioUnitSubType_HALOutput AudioUnit configured for input capture
// from a specific host input device (NOT the system default). An input callback
// pushes captured PCM into an AudioRingBuffer that the device emulation layer
// reads from.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - AudioInputUnit

/// Manages a HAL output AudioUnit configured for input (capture) from a
/// specific host device. Each VM gets its own `AudioInputUnit` pointed at
/// whichever microphone or virtual input the user has configured.
///
/// The input callback pushes captured interleaved Float32 PCM into the
/// attached `AudioRingBuffer`. If the ring buffer overflows, the oldest
/// samples that have not been consumed are effectively lost as new data
/// overwrites the write frontier (the callback drops frames it cannot write).
public final class AudioInputUnit: @unchecked Sendable {

    // MARK: - Properties

    /// The CoreAudio device ID this unit captures from.
    public private(set) var deviceID: AudioDeviceID

    /// The ring buffer that captured audio is written into.
    /// The device emulation layer reads from this buffer.
    public let ringBuffer: AudioRingBuffer

    /// The audio stream format used by this input unit.
    public private(set) var streamFormat: AudioStreamBasicDescription

    /// Whether the unit is currently capturing.
    public private(set) var isRunning: Bool = false

    /// Callback invocation counter for diagnostics.
    var callbackCount: UInt64 = 0

    /// The underlying AudioUnit instance.
    fileprivate var audioUnit: AudioUnit?

    /// Scratch buffer used by the input callback to receive samples from
    /// the AudioUnit before writing them into the ring buffer. Allocated
    /// once during setup to avoid real-time allocations.
    fileprivate var scratchBuffer: UnsafeMutablePointer<Float>?
    fileprivate var scratchBufferSize: Int = 0

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

        try createAndConfigureUnit()
    }

    deinit {
        stop()
        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        if let scratch = scratchBuffer {
            scratch.deallocate()
        }
    }

    // MARK: - Lifecycle

    /// Start capturing audio from the input device.
    public func start() throws {
        guard !isRunning, let unit = audioUnit else { return }

        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "AudioOutputUnitStart (input)")
        }
        isRunning = true
    }

    /// Stop capturing audio.
    public func stop() {
        guard isRunning, let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    /// Switch this input unit to a different device.
    ///
    /// - Parameters:
    ///   - newDeviceID: The new input device to capture from.
    ///   - restart: If `true`, automatically restart capture after switching.
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

    /// Reconfigure the stream format. Stops capture if running.
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
            throw AudioDeviceError.audioUnitError(status, "AudioComponentInstanceNew (input)")
        }
        self.audioUnit = unit

        // 2. Enable input on the input scope (bus 1).
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,  // bus 1 = input
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "Enable input IO")
        }

        // 3. Disable output on the output scope (bus 0).
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,  // bus 0 = output
            &disableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "Disable output IO")
        }

        // 4. Set the input device.
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
                "Set CurrentDevice (input) to \(deviceID)")
        }

        // 5. Set the stream format on the output scope of bus 1.
        //    This tells the AudioUnit what format we want the captured data in.
        var format = streamFormat
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,  // bus 1 = input
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "Set input stream format")
        }

        // 5b. Set the maximum frames per slice to pre-allocate internal buffers.
        var maxSlice: UInt32 = 4096
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxSlice,
                             UInt32(MemoryLayout<UInt32>.size))

        // 5c. Tell the unit to allocate its own buffers for bus 1 input.
        //     Without this, AudioUnitRender may fail with -10863.
        var shouldAllocate: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer,
                             kAudioUnitScope_Output, 1, &shouldAllocate,
                             UInt32(MemoryLayout<UInt32>.size))

        // 6. Allocate scratch buffer for the input callback.
        //    We allocate enough for the maximum expected callback size.
        //    4096 frames * channels is a generous upper bound.
        let maxFrames: Int = 4096
        let totalSamples = maxFrames * Int(streamFormat.mChannelsPerFrame)
        if let old = scratchBuffer { old.deallocate() }
        scratchBuffer = .allocate(capacity: totalSamples)
        scratchBuffer!.initialize(repeating: 0.0, count: totalSamples)
        scratchBufferSize = totalSamples

        // 7. Install the input callback.
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: refCon
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "Set input callback")
        }

        // 8. Initialize the unit.
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw AudioDeviceError.audioUnitError(status, "AudioUnitInitialize (input)")
        }
    }
}

// MARK: - Input callback (C function)

/// The CoreAudio input callback. Called on the real-time audio thread when
/// new audio data is available from the input device. Renders the data from
/// the AudioUnit and pushes it into the ring buffer.
private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let inputUnit = Unmanaged<AudioInputUnit>.fromOpaque(inRefCon)
        .takeUnretainedValue()

    inputUnit.callbackCount += 1
    if inputUnit.callbackCount <= 3 || inputUnit.callbackCount % 5000 == 0 {
        print("[AudioInputUnit] callback #\(inputUnit.callbackCount): \(inNumberFrames) frames, bus=\(inBusNumber)")
    }

    guard let audioUnit = inputUnit.audioUnit,
          let scratch = inputUnit.scratchBuffer else {
        return noErr
    }

    let frameCount = Int(inNumberFrames)
    let channels = Int(inputUnit.streamFormat.mChannelsPerFrame)
    let totalSamples = frameCount * channels

    // Guard against unexpectedly large callback sizes.
    guard totalSamples <= inputUnit.scratchBufferSize else {
        return noErr
    }

    // Set up an AudioBufferList. We provide our scratch buffer but the unit
    // may use its own if ShouldAllocateBuffer is set.
    let bytesPerSample = Int(inputUnit.streamFormat.mBitsPerChannel / 8)
    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: inputUnit.streamFormat.mChannelsPerFrame,
            mDataByteSize: UInt32(totalSamples * bytesPerSample),
            mData: UnsafeMutableRawPointer(scratch)
        )
    )

    // Render input data from the AudioUnit.
    let status = AudioUnitRender(
        audioUnit,
        ioActionFlags,
        inTimeStamp,
        1,  // bus 1 = input
        inNumberFrames,
        &bufferList
    )
    if status != noErr {
        if inputUnit.callbackCount <= 5 {
            print("[AudioInputUnit] AudioUnitRender failed: \(status)")
        }
        return noErr // Return noErr to keep the callback alive
    }

    // The unit may have rendered into its own buffer. Use whatever mData points to.
    let renderedData = bufferList.mBuffers.mData?.assumingMemoryBound(to: Float.self) ?? scratch
    let renderedSamples = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
    let renderedFrames = renderedSamples / channels

    let source = UnsafeBufferPointer<Float>(start: renderedData, count: renderedSamples)
    let written = inputUnit.ringBuffer.write(source, frameCount: renderedFrames)
    if inputUnit.callbackCount <= 5 {
        print("[AudioInputUnit] wrote \(written) frames to ring buffer (avail: \(inputUnit.ringBuffer.framesAvailableForRead))")
    }

    return noErr
}
