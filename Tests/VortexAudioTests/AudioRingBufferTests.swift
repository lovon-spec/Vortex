// AudioRingBufferTests.swift — SPSC ring buffer correctness tests.
// VortexAudioTests

import Testing
import Foundation
@testable import VortexAudio

@Suite("AudioRingBuffer")
struct AudioRingBufferTests {

    // MARK: - Basic read / write

    @Test("Write then read returns same data")
    func writeThenRead() {
        let rb = AudioRingBuffer(frameCapacity: 1024, channelCount: 2)

        // Write 10 stereo frames (20 samples).
        var source = [Float](repeating: 0, count: 20)
        for i in 0..<20 { source[i] = Float(i) }

        let written = source.withUnsafeBufferPointer { buf in
            rb.write(buf, frameCount: 10)
        }
        #expect(written == 10, "Should write all 10 frames")
        #expect(rb.framesAvailableForRead == 10)

        // Read them back.
        var dest = [Float](repeating: -1, count: 20)
        let read = dest.withUnsafeMutableBufferPointer { buf in
            rb.read(buf, frameCount: 10)
        }
        #expect(read == 10, "Should read all 10 frames")
        #expect(dest == source, "Read data should match written data")
        #expect(rb.framesAvailableForRead == 0)
    }

    @Test("Partial read leaves remaining data")
    func partialRead() {
        let rb = AudioRingBuffer(frameCapacity: 1024, channelCount: 1)

        // Write 100 mono frames.
        let source = [Float](repeating: 42.0, count: 100)
        _ = source.withUnsafeBufferPointer { rb.write($0, frameCount: 100) }

        // Read only 30.
        var dest = [Float](repeating: 0, count: 30)
        let read = dest.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 30) }
        #expect(read == 30)
        #expect(rb.framesAvailableForRead == 70)
    }

    @Test("Overflow drops excess frames")
    func overflowDropsExcessFrames() {
        // Small buffer: 8 frames (power of 2) with 1 channel = 8 samples.
        let rb = AudioRingBuffer(frameCapacity: 8, channelCount: 1)
        #expect(rb.capacity == 8,
            "8 is already a power of two, capacity should be 8")

        // Write exactly 8 frames — fills the buffer.
        let source = [Float]((0..<8).map { Float($0) })
        let written1 = source.withUnsafeBufferPointer { rb.write($0, frameCount: 8) }
        #expect(written1 == 8)
        #expect(rb.framesAvailableForWrite == 0)

        // Try to write 4 more — should write 0 because buffer is full.
        let extra = [Float](repeating: 99, count: 4)
        let written2 = extra.withUnsafeBufferPointer { rb.write($0, frameCount: 4) }
        #expect(written2 == 0, "Should not write into a full buffer")
    }

    @Test("Underflow returns zero frames")
    func underflowReturnsZeroFrames() {
        let rb = AudioRingBuffer(frameCapacity: 1024, channelCount: 2)

        // Read from empty buffer.
        var dest = [Float](repeating: -1, count: 20)
        let read = dest.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 10) }
        #expect(read == 0, "Should read 0 frames from empty buffer")

        // Destination should be unchanged.
        #expect(dest.allSatisfy { $0 == -1 },
            "Destination should not be modified on underflow")
    }

    @Test("Partial overflow writes only what fits")
    func partialOverflow() {
        let rb = AudioRingBuffer(frameCapacity: 8, channelCount: 1)

        // Write 6 frames.
        let source = [Float]((0..<6).map { Float($0) })
        let written1 = source.withUnsafeBufferPointer { rb.write($0, frameCount: 6) }
        #expect(written1 == 6)

        // Try to write 5 more — only 2 should fit.
        let more = [Float]((10..<15).map { Float($0) })
        let written2 = more.withUnsafeBufferPointer { rb.write($0, frameCount: 5) }
        #expect(written2 == 2, "Only 2 frames should fit")

        // Read all 8 frames.
        var dest = [Float](repeating: 0, count: 8)
        let read = dest.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 8) }
        #expect(read == 8)
        #expect(dest == [0, 1, 2, 3, 4, 5, 10, 11])
    }

    // MARK: - Wrap-around

    @Test("Wrap-around preserves data integrity")
    func wrapAroundCorrectness() {
        let rb = AudioRingBuffer(frameCapacity: 8, channelCount: 1)

        // Fill with 6, read 6, then write 6 more (wraps around).
        let source1 = [Float]((0..<6).map { Float($0) })
        _ = source1.withUnsafeBufferPointer { rb.write($0, frameCount: 6) }

        var drain = [Float](repeating: 0, count: 6)
        _ = drain.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 6) }
        #expect(rb.framesAvailableForRead == 0)

        // Now write position is at index 6. Writing 6 more wraps around.
        let source2 = [Float]((100..<106).map { Float($0) })
        let written = source2.withUnsafeBufferPointer { rb.write($0, frameCount: 6) }
        #expect(written == 6)

        var result = [Float](repeating: 0, count: 6)
        let read = result.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 6) }
        #expect(read == 6)
        #expect(result == [100, 101, 102, 103, 104, 105])
    }

    // MARK: - Reset

    @Test("Reset clears all buffered data")
    func resetClearsBuffer() {
        let rb = AudioRingBuffer(frameCapacity: 1024, channelCount: 2)

        // Write some data.
        let source = [Float](repeating: 1.0, count: 100)
        _ = source.withUnsafeBufferPointer { rb.write($0, frameCount: 50) }
        #expect(rb.framesAvailableForRead == 50)

        // Reset.
        rb.reset()
        #expect(rb.framesAvailableForRead == 0)
        #expect(rb.framesAvailableForWrite == rb.capacity / rb.channelCount)
    }

    // MARK: - Power of two

    @Test("Non-power-of-two capacity rounds up")
    func powerOfTwoRounding() {
        // 1000 frames * 2 channels = 2000 samples, rounds up to 2048.
        let rb = AudioRingBuffer(frameCapacity: 1000, channelCount: 2)
        #expect(rb.capacity == 2048)
    }

    @Test("Power-of-two capacity stays exact")
    func powerOfTwoExact() {
        // 512 frames * 1 channel = 512, already power of two.
        let rb = AudioRingBuffer(frameCapacity: 512, channelCount: 1)
        #expect(rb.capacity == 512)
    }

    @Test("nextPowerOfTwo computes correctly")
    func nextPowerOfTwo() {
        #expect(AudioRingBuffer.nextPowerOfTwo(1) == 1)
        #expect(AudioRingBuffer.nextPowerOfTwo(2) == 2)
        #expect(AudioRingBuffer.nextPowerOfTwo(3) == 4)
        #expect(AudioRingBuffer.nextPowerOfTwo(5) == 8)
        #expect(AudioRingBuffer.nextPowerOfTwo(7) == 8)
        #expect(AudioRingBuffer.nextPowerOfTwo(1023) == 1024)
        #expect(AudioRingBuffer.nextPowerOfTwo(1024) == 1024)
        #expect(AudioRingBuffer.nextPowerOfTwo(1025) == 2048)
    }

    // MARK: - Channel count

    @Test("Mono buffer works correctly")
    func monoBuffer() {
        let rb = AudioRingBuffer(frameCapacity: 64, channelCount: 1)
        #expect(rb.channelCount == 1)

        let source = [Float]((0..<10).map { Float($0) })
        let written = source.withUnsafeBufferPointer { rb.write($0, frameCount: 10) }
        #expect(written == 10)

        var dest = [Float](repeating: 0, count: 10)
        let read = dest.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 10) }
        #expect(read == 10)
        #expect(dest == source)
    }

    @Test("Quad-channel buffer works correctly")
    func quadChannelBuffer() {
        let rb = AudioRingBuffer(frameCapacity: 64, channelCount: 4)
        #expect(rb.channelCount == 4)

        // 5 frames * 4 channels = 20 samples.
        let source = [Float]((0..<20).map { Float($0) })
        let written = source.withUnsafeBufferPointer { rb.write($0, frameCount: 5) }
        #expect(written == 5)

        var dest = [Float](repeating: 0, count: 20)
        let read = dest.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 5) }
        #expect(read == 5)
        #expect(dest == source)
    }

    // MARK: - Concurrent producer / consumer

    @Test("Concurrent producer/consumer preserves data order")
    func concurrentProducerConsumer() async {
        // Stress test: one thread writes, another reads. Verify data integrity.
        let totalFrames = 100_000
        let channelCount = 2
        let rb = AudioRingBuffer(frameCapacity: 4096, channelCount: channelCount)

        // The producer writes sequential integers so the consumer can verify order.
        let readValues = UnsafeMutableBufferPointer<Float>.allocate(
            capacity: totalFrames * channelCount
        )
        readValues.initialize(repeating: 0)
        defer { readValues.deallocate() }

        let readValuesPtr = readValues.baseAddress!

        // Producer task.
        let producerTask = Task.detached {
            var frameIndex = 0
            while frameIndex < totalFrames {
                let chunkSize = min(128, totalFrames - frameIndex)
                let sampleCount = chunkSize * channelCount
                let samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: sampleCount)
                defer { samples.deallocate() }
                for i in 0..<sampleCount {
                    samples[i] = Float(frameIndex * channelCount + i)
                }

                let written = rb.write(
                    UnsafeBufferPointer(samples),
                    frameCount: chunkSize
                )
                frameIndex += written

                if written == 0 {
                    try? await Task.sleep(for: .microseconds(100))
                }
            }
            return frameIndex
        }

        // Consumer task.
        let consumerTask = Task.detached {
            var frameIndex = 0
            let chunkSamples = 256 * channelCount
            let readBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: chunkSamples)
            defer { readBuf.deallocate() }

            while frameIndex < totalFrames {
                let chunkSize = min(256, totalFrames - frameIndex)
                let read = rb.read(readBuf, frameCount: chunkSize)

                if read > 0 {
                    let samplesRead = read * channelCount
                    let destOffset = frameIndex * channelCount
                    for i in 0..<samplesRead {
                        readValuesPtr[destOffset + i] = readBuf[i]
                    }
                    frameIndex += read
                } else {
                    try? await Task.sleep(for: .microseconds(100))
                }
            }
            return frameIndex
        }

        let totalWritten = await producerTask.value
        let totalRead = await consumerTask.value

        #expect(totalWritten == totalFrames)
        #expect(totalRead == totalFrames)

        // Verify sequential order.
        var firstMismatch: Int? = nil
        for i in 0..<(totalFrames * channelCount) {
            if readValuesPtr[i] != Float(i) {
                firstMismatch = i
                break
            }
        }
        #expect(firstMismatch == nil,
            "Data mismatch at index \(firstMismatch ?? -1)")
    }

    // MARK: - Available counts

    @Test("Available counts update correctly")
    func availableCounts() {
        let rb = AudioRingBuffer(frameCapacity: 16, channelCount: 2)
        // 16 frames * 2 channels = 32 samples. Already power of 2.
        #expect(rb.capacity == 32)
        #expect(rb.framesAvailableForRead == 0)
        #expect(rb.framesAvailableForWrite == 16)
        #expect(rb.availableForRead == 0)
        #expect(rb.availableForWrite == 32)

        // Write 5 frames (10 samples).
        let source = [Float](repeating: 1.0, count: 10)
        _ = source.withUnsafeBufferPointer { rb.write($0, frameCount: 5) }

        #expect(rb.framesAvailableForRead == 5)
        #expect(rb.framesAvailableForWrite == 11)
        #expect(rb.availableForRead == 10)
        #expect(rb.availableForWrite == 22)

        // Read 3 frames (6 samples).
        var dest = [Float](repeating: 0, count: 6)
        _ = dest.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 3) }

        #expect(rb.framesAvailableForRead == 2)
        #expect(rb.framesAvailableForWrite == 14)
    }

    // MARK: - Edge: zero frame operations

    @Test("Zero-frame write is a no-op")
    func zeroFrameWrite() {
        let rb = AudioRingBuffer(frameCapacity: 64, channelCount: 2)
        let source = [Float](repeating: 1.0, count: 0)
        let written = source.withUnsafeBufferPointer { rb.write($0, frameCount: 0) }
        #expect(written == 0)
        #expect(rb.framesAvailableForRead == 0)
    }

    @Test("Zero-frame read is a no-op")
    func zeroFrameRead() {
        let rb = AudioRingBuffer(frameCapacity: 64, channelCount: 2)
        var dest = [Float](repeating: 0, count: 0)
        let read = dest.withUnsafeMutableBufferPointer { rb.read($0, frameCount: 0) }
        #expect(read == 0)
    }
}
