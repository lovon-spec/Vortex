// LatencyInstrumentation.swift -- RT-safe latency measurement for audio pipeline.
// VortexAudio
//
// Provides lock-free timing infrastructure used by VsockAudioBridge (write side)
// and AudioOutputUnit's render callback (read side) to measure the one-way
// output latency: time from PCM_OUTPUT arrival at the bridge to the moment the
// render callback reads those frames from the ring buffer.
//
// Design:
//   - The bridge writes a mach_absolute_time() timestamp atomically each time
//     it pushes PCM into the ring buffer.
//   - The render callback reads that timestamp, computes delta from its own
//     mach_absolute_time(), and stores the delta in a pre-allocated sample array.
//   - All operations on the RT path are wait-free: no allocations, no locks,
//     no syscalls beyond mach_absolute_time() (which is vDSO-fast on ARM64).
//
// The sample array is a fixed-capacity circular buffer. When full, new samples
// overwrite the oldest. Non-RT code (the CLI command) reads completed samples
// to compute statistics.

import Darwin

// MARK: - MachTimeConverter

/// Converts mach_absolute_time() ticks to human-readable time units.
///
/// On Apple Silicon, the timebase is 1:1 (ticks == nanoseconds), but we
/// query the actual timebase for correctness.
public struct MachTimeConverter: Sendable {

    /// Numerator of the mach timebase.
    public let numer: UInt32

    /// Denominator of the mach timebase.
    public let denom: UInt32

    /// Initializes by querying mach_timebase_info.
    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.numer = info.numer
        self.denom = info.denom
    }

    /// Converts a tick delta to nanoseconds.
    @inline(__always)
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        // Overflow-safe: on Apple Silicon numer == denom == 1, so this is identity.
        // On Intel (hypothetical), numer/denom can differ but product fits UInt64
        // for reasonable deltas (< hours).
        return (ticks * UInt64(numer)) / UInt64(denom)
    }

    /// Converts a tick delta to microseconds.
    @inline(__always)
    public func microseconds(fromTicks ticks: UInt64) -> Double {
        Double(nanoseconds(fromTicks: ticks)) / 1000.0
    }

    /// Converts a tick delta to milliseconds.
    @inline(__always)
    public func milliseconds(fromTicks ticks: UInt64) -> Double {
        Double(nanoseconds(fromTicks: ticks)) / 1_000_000.0
    }
}

// MARK: - LatencySample

/// A single latency measurement.
public struct LatencySample: Sendable {
    /// The latency in mach_absolute_time ticks.
    public var ticks: UInt64

    /// Buffer fill level in frames at the time of measurement.
    public var bufferFrames: Int32

    public init(ticks: UInt64 = 0, bufferFrames: Int32 = 0) {
        self.ticks = ticks
        self.bufferFrames = bufferFrames
    }
}

// MARK: - LatencyCollector

/// Lock-free, RT-safe latency sample collector.
///
/// The producer side (render callback) writes samples into a fixed-capacity
/// circular buffer using atomic operations. The consumer side (CLI reporting
/// thread) reads completed samples without interfering with the producer.
///
/// ## Threading model
/// - `recordSample(_:)` is called from the RT audio thread. It is wait-free.
/// - `readTimestamp()` / `writeTimestamp` are used across the bridge write
///   queue and the RT render callback via atomic access.
/// - `drainSamples()` and `statisticsSnapshot()` are called from non-RT
///   threads (CLI reporting). They are safe to call concurrently with
///   `recordSample` but NOT with each other.
public final class LatencyCollector: @unchecked Sendable {

    // MARK: - Configuration

    /// Maximum number of samples in the circular buffer.
    public let capacity: Int

    // MARK: - Storage

    /// Pre-allocated sample storage.
    private let samples: UnsafeMutablePointer<LatencySample>

    /// Write cursor (only incremented by recordSample on the RT thread).
    private let _writePos: UnsafeMutablePointer<Int>

    /// Read cursor (only incremented by drainSamples on the reporting thread).
    private let _readPos: UnsafeMutablePointer<Int>

    /// Bitmask for fast modulo (capacity is power of two).
    private let mask: Int

    /// The latest PCM write timestamp, set by the bridge when it pushes
    /// PCM_OUTPUT data into the ring buffer.
    ///
    /// Accessed atomically: the bridge write queue stores, the RT render
    /// callback loads. On ARM64, aligned 64-bit loads/stores are atomic.
    private let _lastWriteTimestamp: UnsafeMutablePointer<UInt64>

    /// Whether latency instrumentation is active. When false, recordSample
    /// and writeTimestamp are no-ops to avoid overhead during normal operation.
    private let _enabled: UnsafeMutablePointer<UInt32>

    // MARK: - Init / Deinit

    /// Creates a collector with the given sample capacity.
    ///
    /// - Parameter capacity: Number of samples to buffer. Rounded up to
    ///   the next power of two. Default is 8192 (~170 seconds at 48kHz/1024 frames).
    public init(capacity: Int = 8192) {
        let po2 = LatencyCollector.nextPowerOfTwo(max(capacity, 16))
        self.capacity = po2
        self.mask = po2 - 1

        self.samples = .allocate(capacity: po2)
        self.samples.initialize(repeating: LatencySample(), count: po2)

        self._writePos = .allocate(capacity: 1)
        self._writePos.initialize(to: 0)

        self._readPos = .allocate(capacity: 1)
        self._readPos.initialize(to: 0)

        self._lastWriteTimestamp = .allocate(capacity: 1)
        self._lastWriteTimestamp.initialize(to: 0)

        self._enabled = .allocate(capacity: 1)
        self._enabled.initialize(to: 0)
    }

    deinit {
        samples.deinitialize(count: capacity)
        samples.deallocate()
        _writePos.deinitialize(count: 1)
        _writePos.deallocate()
        _readPos.deinitialize(count: 1)
        _readPos.deallocate()
        _lastWriteTimestamp.deinitialize(count: 1)
        _lastWriteTimestamp.deallocate()
        _enabled.deinitialize(count: 1)
        _enabled.deallocate()
    }

    // MARK: - Enable / Disable

    /// Whether instrumentation is active.
    public var isEnabled: Bool {
        get { _enabled.pointee != 0 }
        set {
            OSMemoryBarrier()
            _enabled.pointee = newValue ? 1 : 0
            OSMemoryBarrier()
        }
    }

    // MARK: - Bridge side (write queue)

    /// Stores the current mach_absolute_time as the latest PCM write timestamp.
    ///
    /// Called by the vsock bridge on its write queue when PCM_OUTPUT data is
    /// written into the ring buffer.
    ///
    /// - Important: This is NOT called from the RT thread. It runs on the
    ///   vsock read queue.
    @inline(__always)
    public func storeWriteTimestamp() {
        guard _enabled.pointee != 0 else { return }
        let now = mach_absolute_time()
        OSMemoryBarrier()
        _lastWriteTimestamp.pointee = now
        OSMemoryBarrier()
    }

    /// Reads the latest PCM write timestamp.
    ///
    /// Called by the render callback on the RT thread.
    @inline(__always)
    public func loadWriteTimestamp() -> UInt64 {
        let ts = _lastWriteTimestamp.pointee
        OSMemoryBarrier()
        return ts
    }

    // MARK: - RT side (render callback)

    /// Records a latency sample. Called from the RT render callback.
    ///
    /// - Parameters:
    ///   - ticks: The latency in mach_absolute_time ticks (renderTime - writeTime).
    ///   - bufferFrames: Current ring buffer fill level in frames.
    ///
    /// - Important: This is RT-safe. No allocations, no locks, no syscalls.
    @inline(__always)
    public func recordSample(ticks: UInt64, bufferFrames: Int32) {
        guard _enabled.pointee != 0 else { return }

        let w = _writePos.pointee
        let index = w & mask
        samples[index] = LatencySample(ticks: ticks, bufferFrames: bufferFrames)
        OSMemoryBarrier()
        _writePos.pointee = w &+ 1
        OSMemoryBarrier()
    }

    // MARK: - Reporting side (non-RT)

    /// Drains all available samples into the provided array.
    ///
    /// - Parameter dest: Array to append samples to.
    /// - Returns: Number of samples drained.
    @discardableResult
    public func drainSamples(into dest: inout [LatencySample]) -> Int {
        let w = _writePos.pointee
        OSMemoryBarrier()
        let r = _readPos.pointee
        let available = w &- r

        guard available > 0 else { return 0 }

        // If the producer has lapped us, skip to the most recent `capacity` samples.
        let start: Int
        let count: Int
        if available > capacity {
            // Producer lapped us -- we lost some samples. Skip ahead.
            start = w &- capacity
            count = capacity
        } else {
            start = r
            count = available
        }

        dest.reserveCapacity(dest.count + count)
        for i in 0..<count {
            let index = (start &+ i) & mask
            dest.append(samples[index])
        }

        _readPos.pointee = start &+ count
        OSMemoryBarrier()

        return count
    }

    /// Computes statistics from a collection of samples.
    ///
    /// - Parameter samples: The latency samples to analyze.
    /// - Returns: Statistics, or `nil` if the array is empty.
    public static func computeStatistics(
        from samples: [LatencySample],
        converter: MachTimeConverter
    ) -> LatencyStatistics? {
        guard !samples.isEmpty else { return nil }

        let latenciesMs = samples.map { converter.milliseconds(fromTicks: $0.ticks) }
        let bufferFrames = samples.map { Int($0.bufferFrames) }

        let sorted = latenciesMs.sorted()
        let count = sorted.count

        let sum = sorted.reduce(0.0, +)
        let mean = sum / Double(count)
        let minVal = sorted[0]
        let maxVal = sorted[count - 1]
        let p50 = sorted[count / 2]
        let p95 = sorted[min(Int(Double(count) * 0.95), count - 1)]
        let p99 = sorted[min(Int(Double(count) * 0.99), count - 1)]

        let bufferSum = bufferFrames.reduce(0, +)
        let bufferMean = Double(bufferSum) / Double(count)
        let bufferMin = bufferFrames.min() ?? 0
        let bufferMax = bufferFrames.max() ?? 0

        return LatencyStatistics(
            sampleCount: count,
            minMs: minVal,
            maxMs: maxVal,
            meanMs: mean,
            p50Ms: p50,
            p95Ms: p95,
            p99Ms: p99,
            bufferFramesMean: bufferMean,
            bufferFramesMin: bufferMin,
            bufferFramesMax: bufferMax
        )
    }

    // MARK: - Helpers

    private static func nextPowerOfTwo(_ n: Int) -> Int {
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

// MARK: - LatencyStatistics

/// Aggregated latency statistics from a measurement run.
public struct LatencyStatistics: Sendable, CustomStringConvertible {
    /// Number of samples in this computation.
    public let sampleCount: Int

    /// Minimum latency in milliseconds.
    public let minMs: Double

    /// Maximum latency in milliseconds.
    public let maxMs: Double

    /// Mean latency in milliseconds.
    public let meanMs: Double

    /// Median (p50) latency in milliseconds.
    public let p50Ms: Double

    /// 95th percentile latency in milliseconds.
    public let p95Ms: Double

    /// 99th percentile latency in milliseconds.
    public let p99Ms: Double

    /// Mean ring buffer fill level in frames.
    public let bufferFramesMean: Double

    /// Minimum ring buffer fill level in frames.
    public let bufferFramesMin: Int

    /// Maximum ring buffer fill level in frames.
    public let bufferFramesMax: Int

    public var description: String {
        """
        Latency Statistics (\(sampleCount) samples):
          min:  \(String(format: "%.3f", minMs)) ms
          max:  \(String(format: "%.3f", maxMs)) ms
          mean: \(String(format: "%.3f", meanMs)) ms
          p50:  \(String(format: "%.3f", p50Ms)) ms
          p95:  \(String(format: "%.3f", p95Ms)) ms
          p99:  \(String(format: "%.3f", p99Ms)) ms

        Buffer Depth (frames):
          min:  \(bufferFramesMin)
          max:  \(bufferFramesMax)
          mean: \(String(format: "%.1f", bufferFramesMean))
        """
    }

    /// Whether the output latency target of <10ms is met at p95.
    public var meetsLatencyTarget: Bool {
        p95Ms < 10.0
    }

    /// Whether the buffer depth is stable (max - min < 2x mean).
    public var bufferIsStable: Bool {
        guard bufferFramesMean > 0 else { return false }
        let range = Double(bufferFramesMax - bufferFramesMin)
        return range < 2.0 * bufferFramesMean
    }
}
