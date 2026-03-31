// AudioRingBuffer.swift — Lock-free SPSC ring buffer for real-time audio.
// VortexAudio
//
// Single-producer, single-consumer ring buffer suitable for use on the CoreAudio
// real-time thread. All operations are wait-free: no locks, no allocations, no
// syscalls after initialization. Buffer capacity is always a power of two so that
// index wrapping can use bitwise AND instead of modulo.

import Darwin

// MARK: - AudioRingBuffer

/// A lock-free, single-producer / single-consumer ring buffer designed for
/// real-time audio data transfer between the CoreAudio render callback and
/// the application layer.
///
/// - Important: This type is **not** safe for multiple concurrent writers or
///   multiple concurrent readers. It is designed for exactly one producer thread
///   and one consumer thread (the classic SPSC pattern).
///
/// The buffer stores interleaved `Float` samples. For stereo audio at 48 kHz
/// with a 100 ms buffer, you would allocate `48000 * 2 * 0.1 = 9600` frames
/// (which rounds up to the next power of two: 16384).
public final class AudioRingBuffer: @unchecked Sendable {

    // MARK: - Storage

    /// Raw sample storage. Allocated once at init, never reallocated.
    private let buffer: UnsafeMutablePointer<Float>

    /// Total number of Float elements in `buffer`. Always a power of two.
    public let capacity: Int

    /// Bitmask for fast modulo: `index & mask` == `index % capacity`.
    private let mask: Int

    /// Number of interleaved channels (e.g. 2 for stereo).
    public let channelCount: Int

    // MARK: - Cursors
    //
    // These are accessed atomically using os_atomic_load / os_atomic_store.
    // On ARM64 (Apple Silicon), aligned pointer-width loads and stores are
    // naturally atomic. We use OSMemoryBarrier (full fence) to provide the
    // acquire/release semantics needed for the SPSC protocol.

    /// Write cursor — only mutated by the producer.
    private let _writePosition: UnsafeMutablePointer<Int>

    /// Read cursor — only mutated by the consumer.
    private let _readPosition: UnsafeMutablePointer<Int>

    // MARK: - Init / Deinit

    /// Creates a ring buffer.
    ///
    /// - Parameters:
    ///   - frameCapacity: Desired capacity in **frames** (samples per channel).
    ///     Rounded up to the next power of two internally.
    ///   - channelCount: Number of interleaved channels (default 2 for stereo).
    public init(frameCapacity: Int, channelCount: Int = 2) {
        precondition(frameCapacity > 0, "frameCapacity must be positive")
        precondition(channelCount > 0, "channelCount must be positive")

        self.channelCount = channelCount

        // Round up to next power of two in sample (not frame) space.
        let requestedSamples = frameCapacity * channelCount
        let po2 = AudioRingBuffer.nextPowerOfTwo(requestedSamples)
        self.capacity = po2
        self.mask = po2 - 1

        self.buffer = .allocate(capacity: po2)
        self.buffer.initialize(repeating: 0.0, count: po2)

        self._writePosition = .allocate(capacity: 1)
        self._writePosition.initialize(to: 0)
        self._readPosition = .allocate(capacity: 1)
        self._readPosition.initialize(to: 0)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
        _writePosition.deinitialize(count: 1)
        _writePosition.deallocate()
        _readPosition.deinitialize(count: 1)
        _readPosition.deallocate()
    }

    // MARK: - Atomic helpers
    //
    // On ARM64, aligned natural-width loads/stores are atomic. We pair them
    // with OSMemoryBarrier to get acquire/release semantics. This is the
    // standard pattern used by Apple's own audio ring buffer examples and
    // avoids any dependency on Synchronization (macOS 15+).

    /// Acquire-load: read the value, then issue a barrier so subsequent
    /// reads/writes cannot be reordered before this load.
    @inline(__always)
    private static func atomicLoad(_ ptr: UnsafeMutablePointer<Int>) -> Int {
        let value = ptr.pointee
        OSMemoryBarrier()
        return value
    }

    /// Release-store: issue a barrier so all preceding writes are visible,
    /// then store the value.
    @inline(__always)
    private static func atomicStore(_ ptr: UnsafeMutablePointer<Int>, _ value: Int) {
        OSMemoryBarrier()
        ptr.pointee = value
    }

    // MARK: - Public API

    /// Number of samples available for reading.
    public var availableForRead: Int {
        let w = Self.atomicLoad(_writePosition)
        let r = Self.atomicLoad(_readPosition)
        return w &- r
    }

    /// Number of samples that can be written before the buffer is full.
    public var availableForWrite: Int {
        return capacity - availableForRead
    }

    /// Number of **frames** available for reading (samples / channelCount).
    public var framesAvailableForRead: Int {
        return availableForRead / channelCount
    }

    /// Number of **frames** that can be written (samples / channelCount).
    public var framesAvailableForWrite: Int {
        return availableForWrite / channelCount
    }

    /// Write interleaved samples into the ring buffer.
    ///
    /// - Parameters:
    ///   - source: Pointer to interleaved Float samples.
    ///   - frameCount: Number of frames to write.
    /// - Returns: Number of frames actually written (may be less than requested
    ///   if the buffer is nearly full).
    @discardableResult
    public func write(_ source: UnsafeBufferPointer<Float>, frameCount: Int) -> Int {
        let samplesToWrite = frameCount * channelCount
        let available = availableForWrite
        let count = min(samplesToWrite, available)
        if count == 0 { return 0 }

        // Relaxed load is fine here since only the producer writes this position.
        let w = _writePosition.pointee
        let startIndex = w & mask

        let firstChunk = min(count, capacity - startIndex)
        let secondChunk = count - firstChunk

        // Copy first contiguous region.
        buffer.advanced(by: startIndex)
            .update(from: source.baseAddress!, count: firstChunk)

        // Copy wrap-around region if needed.
        if secondChunk > 0 {
            buffer.update(from: source.baseAddress!.advanced(by: firstChunk),
                          count: secondChunk)
        }

        // Release-store the new write position so the consumer sees the data.
        Self.atomicStore(_writePosition, w &+ count)

        return count / channelCount
    }

    /// Read interleaved samples from the ring buffer.
    ///
    /// - Parameters:
    ///   - destination: Destination buffer for interleaved Float samples.
    ///   - frameCount: Number of frames to read.
    /// - Returns: Number of frames actually read (may be less than requested
    ///   if the buffer does not contain enough data).
    @discardableResult
    public func read(_ destination: UnsafeMutableBufferPointer<Float>, frameCount: Int) -> Int {
        let samplesToRead = frameCount * channelCount
        let available = availableForRead
        let count = min(samplesToRead, available)
        if count == 0 { return 0 }

        // Relaxed load is fine here since only the consumer writes this position.
        let r = _readPosition.pointee
        let startIndex = r & mask

        let firstChunk = min(count, capacity - startIndex)
        let secondChunk = count - firstChunk

        // Copy first contiguous region.
        destination.baseAddress!
            .update(from: buffer.advanced(by: startIndex), count: firstChunk)

        // Copy wrap-around region if needed.
        if secondChunk > 0 {
            destination.baseAddress!.advanced(by: firstChunk)
                .update(from: buffer, count: secondChunk)
        }

        // Release-store the new read position so the producer sees freed space.
        Self.atomicStore(_readPosition, r &+ count)

        return count / channelCount
    }

    /// Discard all buffered data and reset cursors.
    ///
    /// - Warning: Only safe to call when neither producer nor consumer is active.
    public func reset() {
        _writePosition.pointee = 0
        _readPosition.pointee = 0
        OSMemoryBarrier()
    }

    // MARK: - Helpers

    /// Round up to the next power of two (or return `n` if already a power of two).
    internal static func nextPowerOfTwo(_ n: Int) -> Int {
        precondition(n > 0)
        if n & (n - 1) == 0 { return n }
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
