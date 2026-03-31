// AudioFormatConverter.swift — Sample rate / format conversion.
// VortexAudio
//
// Wraps AudioConverterRef from AudioToolbox to convert between the guest
// VM's audio stream format and the host device's native format. Handles
// sample rate conversion (e.g. 44100 <-> 48000), format conversion
// (Int16 <-> Float32), and channel count differences.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - AudioFormatConverter

/// Converts audio data between two `AudioStreamBasicDescription` formats
/// using Apple's `AudioConverterRef`.
///
/// Typical use: the guest VM produces 44100 Hz Int16 stereo, but the host
/// device expects 48000 Hz Float32 stereo. Create a converter for this
/// pair of formats and call `convert(_:)` to transform buffers.
public final class AudioFormatConverter: @unchecked Sendable {

    // MARK: - Properties

    /// The source format.
    public let sourceFormat: AudioStreamBasicDescription

    /// The destination format.
    public let destinationFormat: AudioStreamBasicDescription

    /// The underlying AudioConverter.
    private var converter: AudioConverterRef?

    /// Whether the converter performs sample rate conversion.
    public var performsSampleRateConversion: Bool {
        sourceFormat.mSampleRate != destinationFormat.mSampleRate
    }

    /// Whether the converter changes the sample format (e.g. int <-> float).
    public var performsFormatConversion: Bool {
        sourceFormat.mBitsPerChannel != destinationFormat.mBitsPerChannel ||
        sourceFormat.mFormatFlags != destinationFormat.mFormatFlags
    }

    // MARK: - Init / Deinit

    /// Creates a converter between two audio formats.
    ///
    /// - Parameters:
    ///   - sourceFormat: The format of the input data.
    ///   - destinationFormat: The desired output format.
    public init(
        from sourceFormat: AudioStreamBasicDescription,
        to destinationFormat: AudioStreamBasicDescription
    ) throws {
        self.sourceFormat = sourceFormat
        self.destinationFormat = destinationFormat

        var src = sourceFormat
        var dst = destinationFormat
        var converterRef: AudioConverterRef?

        let status = AudioConverterNew(&src, &dst, &converterRef)
        guard status == noErr, let converterRef = converterRef else {
            throw AudioDeviceError.converterError(status,
                "AudioConverterNew from \(Self.formatDescription(sourceFormat)) " +
                "to \(Self.formatDescription(destinationFormat))")
        }
        self.converter = converterRef

        // If doing sample rate conversion, set the quality to medium
        // (good balance of CPU and quality for real-time use).
        if performsSampleRateConversion {
            var quality = UInt32(kAudioConverterQuality_Medium)
            AudioConverterSetProperty(
                converterRef,
                kAudioConverterSampleRateConverterQuality,
                UInt32(MemoryLayout<UInt32>.size),
                &quality
            )
        }
    }

    deinit {
        if let converter = converter {
            AudioConverterDispose(converter)
        }
    }

    // MARK: - Conversion

    /// Convert a buffer of audio data from the source format to the
    /// destination format.
    ///
    /// - Parameters:
    ///   - sourceData: Raw bytes in the source format.
    ///   - sourceFrameCount: Number of frames in the source data.
    /// - Returns: A tuple of (converted data bytes, frame count in destination format).
    public func convert(
        _ sourceData: UnsafeRawPointer,
        sourceFrameCount: UInt32
    ) throws -> (data: [UInt8], frameCount: UInt32) {
        guard let converter = converter else {
            throw AudioDeviceError.converterError(
                OSStatus(kAudioConverterErr_UnspecifiedError),
                "Converter has been disposed"
            )
        }

        // Calculate output buffer size.
        // When sample rate changes, output frame count differs from input.
        let ratio = destinationFormat.mSampleRate / sourceFormat.mSampleRate
        let outputFrameCount = UInt32(ceil(Double(sourceFrameCount) * ratio))
        let outputByteCount = outputFrameCount * destinationFormat.mBytesPerFrame

        var outputData = [UInt8](repeating: 0, count: Int(outputByteCount))
        let outputDataSize = outputByteCount

        // Set up the input data provider context.
        var context = ConverterInputContext(
            sourceData: sourceData,
            sourceBytesRemaining: sourceFrameCount * sourceFormat.mBytesPerFrame,
            sourceFormat: sourceFormat
        )

        var actualOutputFrames = outputFrameCount

        let status = outputData.withUnsafeMutableBufferPointer { outBuf in
            var outputBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: destinationFormat.mChannelsPerFrame,
                    mDataByteSize: outputDataSize,
                    mData: outBuf.baseAddress
                )
            )

            let packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>? = nil

            return withUnsafeMutablePointer(to: &context) { ctxPtr in
                AudioConverterFillComplexBuffer(
                    converter,
                    converterInputCallback,
                    ctxPtr,
                    &actualOutputFrames,
                    &outputBufferList,
                    packetDescriptions
                )
            }
        }

        // kAudioConverterErr_InvalidInputSize is not fatal — it means
        // we consumed all input before filling the output completely.
        if status != noErr && status != 1 /* kAudioConverterErr_InvalidInputSize (100) */ {
            // Accept underflow — the converter consumed all available input.
            let underflow: OSStatus = -74 // insz
            if status != underflow {
                throw AudioDeviceError.converterError(status, "AudioConverterFillComplexBuffer")
            }
        }

        let actualBytes = Int(actualOutputFrames * destinationFormat.mBytesPerFrame)
        if actualBytes < outputData.count {
            outputData.removeSubrange(actualBytes..<outputData.count)
        }

        return (data: outputData, frameCount: actualOutputFrames)
    }

    /// Convenience: convert Float32 interleaved samples to the destination format.
    ///
    /// - Parameters:
    ///   - samples: Source samples in the source format.
    ///   - frameCount: Number of frames.
    /// - Returns: Converted data as raw bytes and the output frame count.
    public func convert(
        samples: UnsafeBufferPointer<Float>,
        frameCount: UInt32
    ) throws -> (data: [UInt8], frameCount: UInt32) {
        guard let base = samples.baseAddress else {
            throw AudioDeviceError.converterError(
                OSStatus(kAudioConverterErr_UnspecifiedError),
                "Nil source buffer"
            )
        }
        return try convert(UnsafeRawPointer(base), sourceFrameCount: frameCount)
    }

    /// Reset the converter's internal state (e.g. after a seek or discontinuity).
    public func reset() throws {
        guard let converter = converter else { return }
        let status = AudioConverterReset(converter)
        guard status == noErr else {
            throw AudioDeviceError.converterError(status, "AudioConverterReset")
        }
    }

    // MARK: - Helpers

    /// Human-readable description of an audio format.
    public static func formatDescription(
        _ format: AudioStreamBasicDescription
    ) -> String {
        let type: String
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            type = "Float\(format.mBitsPerChannel)"
        } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            type = "Int\(format.mBitsPerChannel)"
        } else {
            type = "UInt\(format.mBitsPerChannel)"
        }
        return "\(type)/\(Int(format.mSampleRate))Hz/\(format.mChannelsPerFrame)ch"
    }
}

// MARK: - Converter input callback context

/// Context passed to the AudioConverter input data proc.
private struct ConverterInputContext {
    var sourceData: UnsafeRawPointer
    var sourceBytesRemaining: UInt32
    var sourceFormat: AudioStreamBasicDescription
}

// MARK: - Converter input callback (C function)

/// Called by `AudioConverterFillComplexBuffer` when it needs more input data.
private func converterInputCallback(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return OSStatus(kAudioConverterErr_UnspecifiedError)
    }

    let context = userData.assumingMemoryBound(to: ConverterInputContext.self)

    if context.pointee.sourceBytesRemaining == 0 {
        ioNumberDataPackets.pointee = 0
        return OSStatus(100) // No more data available.
    }

    let bytesPerPacket = context.pointee.sourceFormat.mBytesPerPacket
    let requestedPackets = ioNumberDataPackets.pointee
    let availablePackets = context.pointee.sourceBytesRemaining / bytesPerPacket
    let packetsToProvide = min(requestedPackets, availablePackets)
    let bytesToProvide = packetsToProvide * bytesPerPacket

    // Point the converter at our source data (no copy needed).
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
        mutating: context.pointee.sourceData
    )
    ioData.pointee.mBuffers.mDataByteSize = bytesToProvide
    ioData.pointee.mBuffers.mNumberChannels =
        context.pointee.sourceFormat.mChannelsPerFrame

    ioNumberDataPackets.pointee = packetsToProvide

    // Advance the source pointer.
    context.pointee.sourceData = context.pointee.sourceData
        .advanced(by: Int(bytesToProvide))
    context.pointee.sourceBytesRemaining -= bytesToProvide

    return noErr
}
