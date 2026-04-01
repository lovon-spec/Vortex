// VortexAudioDaemon.swift — Guest-side vsock audio client.
// VortexAudioDaemon
//
// Runs inside the macOS guest VM as a LaunchDaemon. Bridges the guest's
// CoreAudio HAL plugin to the host over vsock, using POSIX shared memory
// for lock-free IPC with the HAL plugin (which runs in coreaudiod).
//
// Architecture:
//   Guest HAL plugin (coreaudiod process)
//       |  (POSIX shared memory: /vortex-audio)
//       v
//   VortexAudioDaemon (this process)
//       |  (vsock AF_VSOCK socket)
//       v
//   Host VsockAudioBridge (Sources/VortexVZ/VsockAudioBridge.swift)
//       |
//       v
//   Host CoreAudio (per-VM device routing)
//
// Wire protocol matches VsockAudioBridge:
//   [4 bytes: message type (UInt32 LE)]
//   [4 bytes: payload length (UInt32 LE)]
//   [N bytes: payload]
//
// Shared memory protocol (matches VortexSharedAudio.h):
//   The HAL plugin creates /vortex-audio via shm_open. This daemon opens
//   it and maps the VortexSharedAudioState structure. Ring buffer positions
//   are atomic uint64s with acquire/release ordering.
//   - Output ring: plugin is producer (WriteMix), daemon is consumer.
//   - Input ring:  daemon is producer, plugin is consumer (ReadInput).
//
// Build note: This file is a standalone daemon. It does NOT depend on any
// Vortex modules — it runs inside the guest, not the host. It should be
// compiled separately (e.g., via its own Package.swift or Xcode target)
// targeting the guest macOS SDK.

import Darwin
import Foundation

// MARK: - Constants

/// The TCP port for Vortex audio transport. Must match host bridge.
private let VORTEX_AUDIO_PORT: UInt16 = 5198

/// Default host gateway IP for VZ NAT networking.
/// The guest can override this with --host flag.
private var hostAddress: String = "192.168.64.1"

/// How long to wait between reconnection attempts (seconds).
private let RECONNECT_DELAY: TimeInterval = 2.0

/// Read buffer size for incoming messages.
private let READ_BUFFER_SIZE = 64 * 1024

/// Default audio format — 48 kHz stereo Float32.
private let DEFAULT_SAMPLE_RATE: UInt32 = 48000
private let DEFAULT_CHANNELS: UInt32 = 2
private let DEFAULT_BITS_PER_SAMPLE: UInt32 = 32
private let DEFAULT_IS_FLOAT: Bool = true

// MARK: - Shared Memory Constants (must match VortexSharedAudio.h)

/// POSIX shared memory name. Must match VORTEX_SHM_NAME in VortexSharedAudio.h.
private let SHM_NAME = "/vortex-audio"

/// Ring buffer capacity in frames. Must match VORTEX_RING_FRAMES.
private let SHM_RING_FRAMES: Int = 65536

/// Maximum channels. Must match VORTEX_MAX_CHANNELS.
private let SHM_MAX_CHANNELS: Int = 2

/// Ring capacity in samples (frames * channels). Must match VORTEX_RING_SAMPLES.
private let SHM_RING_SAMPLES: Int = 65536 * 2  // VORTEX_RING_FRAMES * VORTEX_MAX_CHANNELS

/// Mask for wrapping ring positions. Must match VORTEX_RING_MASK.
private let SHM_RING_MASK: UInt64 = UInt64(65536 * 2 - 1)

/// Magic value to verify shm is valid. Must match VORTEX_SHM_MAGIC.
private let SHM_MAGIC: UInt32 = 0x5658_5348  // "VXSH"

/// Expected version. Must match VORTEX_SHM_VERSION.
private let SHM_VERSION: UInt32 = 1

/// How long to wait for the HAL plugin to create the shm segment (seconds).
private let SHM_ATTACH_TIMEOUT: TimeInterval = 30.0

/// Polling interval when waiting for the shm segment to appear.
private let SHM_ATTACH_POLL_INTERVAL: useconds_t = 500_000  // 0.5s

// MARK: - Message Types

/// Mirror of VsockAudioMessageType from the host side.
private enum MessageType: UInt32 {
    case configure    = 0x01
    case pcmOutput    = 0x02
    case pcmInput     = 0x03
    case start        = 0x04
    case stop         = 0x05
    case latencyQuery = 0x06
    case latencyReply = 0x07
}

// MARK: - VortexAudioDaemon

/// Guest-side daemon that tunnels audio over vsock to the host.
///
/// This daemon:
/// 1. Attaches to the HAL plugin's POSIX shared memory (`/vortex-audio`).
/// 2. Connects to the host on vsock port 5198.
/// 3. Sends a CONFIGURE message with the audio format (read from shm).
/// 4. Sends a START message to begin streaming.
/// 5. Reads audio from the shared output ring and sends PCM_OUTPUT over vsock.
/// 6. Receives PCM_INPUT from the host and writes to the shared input ring.
/// 7. Handles reconnection if the connection drops.
///
/// The shared memory region is created by the HAL plugin (which runs in
/// coreaudiod). This daemon attaches as a consumer of the output ring and
/// a producer of the input ring. All coordination is via atomic positions.
final class VortexAudioDaemon {

    // MARK: - Properties

    /// The connected vsock socket file descriptor, or -1 if disconnected.
    private var socketFD: Int32 = -1

    /// Whether the daemon should keep running.
    private var shouldRun = true

    /// When true, emit detailed diagnostic messages (connection attempts,
    /// shm validation, latency reports, sample rate changes). When false,
    /// only lifecycle events (start, stop, connect, disconnect, errors) are logged.
    var verbose: Bool = false

    /// The audio format we negotiate with the host.
    private var format: AudioFormat

    /// Read buffer for incoming vsock messages (pre-allocated).
    private var readBuffer: UnsafeMutablePointer<UInt8>

    /// Scratch buffer for reading samples from the output ring before sending.
    /// Sized to hold one full read chunk (SHM_RING_SAMPLES floats).
    private var outputScratch: UnsafeMutablePointer<Float>

    /// Timer interval for polling the output ring buffer.
    private let outputPollInterval: TimeInterval = 0.005 // 5ms

    // -- Shared memory --

    /// Pointer to the mapped shared memory region, or nil if not yet attached.
    private var sharedState: UnsafeMutablePointer<UInt8>?

    /// Size of the mapped region (for munmap).
    private var shmMappedSize: Int = 0

    /// File descriptor for the shm segment (-1 if not open).
    private var shmFD: Int32 = -1

    // MARK: - Computed shm accessors

    /// Typed pointer to the shared state header. Only valid when sharedState != nil.
    /// We use byte-offset arithmetic to access fields so that we do not need to
    /// import the C header from Swift. The layout matches VortexSharedAudioState.
    private var shmBase: UnsafeMutableRawPointer? {
        guard let base = sharedState else { return nil }
        return UnsafeMutableRawPointer(base)
    }

    // Field offsets within VortexSharedAudioState (must match C struct layout):
    //   0: _Atomic uint32_t magic
    //   4: _Atomic uint32_t version
    //   8: _Atomic uint32_t sampleRate
    //  12: _Atomic uint32_t channels
    //  16: _Atomic uint32_t isActive
    //  20: uint32_t _reserved0
    //  24: _Atomic uint64_t outputWritePos
    //  32: _Atomic uint64_t outputReadPos
    //  40: _Atomic uint64_t inputWritePos
    //  48: _Atomic uint64_t inputReadPos
    //  56: float outputBuffer[RING_SAMPLES]  -- 65536*2*4 = 524288 bytes
    //  56+524288 = 524344: float inputBuffer[RING_SAMPLES]
    private static let offMagic:          Int = 0
    private static let offVersion:        Int = 4
    private static let offSampleRate:     Int = 8
    private static let offChannels:       Int = 12
    private static let offIsActive:       Int = 16
    private static let offOutputWritePos: Int = 24
    private static let offOutputReadPos:  Int = 32
    private static let offInputWritePos:  Int = 40
    private static let offInputReadPos:   Int = 48
    private static let offOutputBuffer:   Int = 56
    private static let offInputBuffer:    Int = 56 + (SHM_RING_SAMPLES * MemoryLayout<Float>.size)

    // MARK: - Init

    init(
        sampleRate: UInt32 = DEFAULT_SAMPLE_RATE,
        channels: UInt32 = DEFAULT_CHANNELS,
        bitsPerSample: UInt32 = DEFAULT_BITS_PER_SAMPLE,
        isFloat: Bool = DEFAULT_IS_FLOAT
    ) {
        self.format = AudioFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            isFloat: isFloat
        )

        readBuffer = .allocate(capacity: READ_BUFFER_SIZE)
        readBuffer.initialize(repeating: 0, count: READ_BUFFER_SIZE)

        outputScratch = .allocate(capacity: SHM_RING_SAMPLES)
        outputScratch.initialize(repeating: 0, count: SHM_RING_SAMPLES)
    }

    deinit {
        readBuffer.deallocate()
        outputScratch.deallocate()
        detachSharedMemory()
        disconnect()
    }

    // MARK: - Main Loop

    /// Entry point. Runs the connection/reconnection loop indefinitely.
    func run() {
        // Install signal handlers for clean shutdown.
        signal(SIGTERM) { _ in
            // Will cause shouldRun to be checked on next iteration.
        }
        signal(SIGINT) { _ in }

        log("VortexAudioDaemon starting (format: \(format.sampleRate)Hz, "
            + "\(format.channels)ch, \(format.bitsPerSample)bit, "
            + "float=\(format.isFloat))")

        // Attach to the HAL plugin's shared memory. This blocks until the
        // plugin creates the segment or the timeout expires.
        if !attachSharedMemory() {
            log("ERROR: Failed to attach shared memory -- exiting")
            return
        }
        log("Attached to shared memory '\(SHM_NAME)'")

        // Read the format from shared memory (the plugin is authoritative).
        updateFormatFromShm()

        while shouldRun {
            if connect() {
                log("Connected to host vsock port \(VORTEX_AUDIO_PORT)")
                updateFormatFromShm()
                sendConfigure()
                sendStart()
                runStreamingLoop()
                sendStop()
                disconnect()
            }

            if shouldRun {
                log("Reconnecting in \(RECONNECT_DELAY)s...")
                Thread.sleep(forTimeInterval: RECONNECT_DELAY)
            }
        }

        detachSharedMemory()
        log("VortexAudioDaemon exiting")
    }

    // MARK: - Connection

    /// Creates a TCP socket and connects to the host bridge.
    ///
    /// - Returns: `true` if the connection was established.
    private func connect() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logVerbose("socket() failed: errno \(errno) (\(errnoString()))")
            return false
        }

        // Resolve host address.
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(VORTEX_AUDIO_PORT).bigEndian
        guard inet_pton(AF_INET, hostAddress, &addr.sin_addr) == 1 else {
            logVerbose("Invalid host address: \(hostAddress)")
            close(fd)
            return false
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            logVerbose("connect(\(hostAddress):\(VORTEX_AUDIO_PORT)) failed: errno \(errno) (\(errnoString()))")
            close(fd)
            return false
        }

        log("Connected to host at \(hostAddress):\(VORTEX_AUDIO_PORT)")
        self.socketFD = fd
        return true
    }

    /// Closes the vsock connection.
    private func disconnect() {
        guard socketFD >= 0 else { return }
        close(socketFD)
        socketFD = -1
    }

    // MARK: - Streaming Loop

    /// Main streaming loop: polls shared memory for output data to send
    /// over vsock, and receives input data from the host to write into
    /// the shared input ring.
    private func runStreamingLoop() {
        // Set the socket to non-blocking for reads so we can interleave
        // read/write in a single loop.
        var flags = fcntl(socketFD, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(socketFD, F_SETFL, flags)

        while shouldRun {
            // 1. Check for incoming data from host (PCM_INPUT, LATENCY_REPLY).
            if !pollAndReadMessages() {
                // Connection dropped.
                break
            }

            // 2. If IO is active, read from shared output ring and send.
            if shmIsActive() {
                sendOutputDataFromShm()
            }

            // 3. Check for sample rate change in shared memory.
            checkForSampleRateChange()

            // 4. Brief sleep to avoid busy-waiting.
            //    5ms is ~4x per audio callback at 48kHz/1024 frames.
            usleep(5000)
        }
    }

    /// Polls the socket for readable data and processes any complete messages.
    ///
    /// - Returns: `false` if the connection was lost.
    private func pollAndReadMessages() -> Bool {
        var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 0) // Non-blocking poll.

        guard pollResult >= 0 else {
            return errno == EINTR // Interrupted is OK, other errors are not.
        }

        guard pollFD.revents & Int16(POLLIN) != 0 else {
            return true // No data available, that's fine.
        }

        // Check for hangup/error.
        if pollFD.revents & Int16(POLLHUP | POLLERR) != 0 {
            return false
        }

        // Read the header.
        var headerBuf = [UInt8](repeating: 0, count: 8)
        let headerRead = readExactly(fd: socketFD, buffer: &headerBuf, count: 8)
        guard headerRead == 8 else { return false }

        let msgType = headerBuf.withUnsafeBytes { buf -> UInt32 in
            UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let payloadLen = headerBuf.withUnsafeBytes { buf -> UInt32 in
            UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }

        // Read payload.
        var payload = [UInt8]()
        if payloadLen > 0 && payloadLen <= 8 * 1024 * 1024 {
            payload = [UInt8](repeating: 0, count: Int(payloadLen))
            let payloadRead = readExactly(
                fd: socketFD, buffer: &payload, count: Int(payloadLen)
            )
            guard payloadRead == Int(payloadLen) else { return false }
        }

        // Dispatch.
        switch MessageType(rawValue: msgType) {
        case .pcmInput:
            handlePCMInput(payload: payload)
        case .latencyReply:
            handleLatencyReply(payload: payload)
        default:
            break // Ignore unknown or irrelevant messages.
        }

        return true
    }

    // MARK: - Message Sending

    /// Sends the CONFIGURE message with our audio format.
    private func sendConfigure() {
        var payload = [UInt8]()
        payload.reserveCapacity(13)

        var sr = format.sampleRate.littleEndian
        var ch = format.channels.littleEndian
        var bps = format.bitsPerSample.littleEndian
        let fl: UInt8 = format.isFloat ? 1 : 0

        withUnsafeBytes(of: &sr) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bps) { payload.append(contentsOf: $0) }
        payload.append(fl)

        sendMessage(type: .configure, payload: payload)
    }

    /// Sends the START message.
    private func sendStart() {
        sendMessage(type: .start, payload: [])
    }

    /// Sends the STOP message.
    private func sendStop() {
        sendMessage(type: .stop, payload: [])
    }

    /// Reads from the shared output ring buffer and sends PCM_OUTPUT messages
    /// over vsock. The HAL plugin is the producer; we are the consumer.
    private func sendOutputDataFromShm() {
        guard let base = shmBase else { return }

        // Load positions atomically (acquire on writePos to see the producer's data).
        let wPtr = base.advanced(by: Self.offOutputWritePos)
            .assumingMemoryBound(to: UInt64.self)
        let rPtr = base.advanced(by: Self.offOutputReadPos)
            .assumingMemoryBound(to: UInt64.self)

        let w = atomicLoadU64Acquire(wPtr)
        let r = atomicLoadU64Relaxed(rPtr)

        let available = UInt32(truncatingIfNeeded: w &- r)
        guard available > 0 else { return }

        // Read at most one vsock payload worth of samples.
        let maxSamples = READ_BUFFER_SIZE / MemoryLayout<Float>.size
        let toRead = min(Int(available), maxSamples)

        // Copy from the ring into our scratch buffer (handles wrap-around).
        let bufferBase = base.advanced(by: Self.offOutputBuffer)
            .assumingMemoryBound(to: Float.self)

        let startIdx = Int(r & SHM_RING_MASK)
        let firstChunk = min(toRead, SHM_RING_SAMPLES - startIdx)
        let secondChunk = toRead - firstChunk

        memcpy(outputScratch,
               bufferBase.advanced(by: startIdx),
               firstChunk * MemoryLayout<Float>.size)
        if secondChunk > 0 {
            memcpy(outputScratch.advanced(by: firstChunk),
                   bufferBase,
                   secondChunk * MemoryLayout<Float>.size)
        }

        // Advance the read position (release so the producer sees we consumed).
        atomicStoreU64Release(rPtr, r &+ UInt64(toRead))

        // Send as PCM_OUTPUT over vsock.
        let byteCount = toRead * MemoryLayout<Float>.size
        let payload = Array(UnsafeBufferPointer(
            start: UnsafeRawPointer(outputScratch)
                .assumingMemoryBound(to: UInt8.self),
            count: byteCount))
        sendMessage(type: .pcmOutput, payload: payload)
    }

    /// Sends a raw message over the vsock socket.
    private func sendMessage(type: MessageType, payload: [UInt8]) {
        guard socketFD >= 0 else { return }

        var header = [UInt8](repeating: 0, count: 8)
        var typeLE = type.rawValue.littleEndian
        var lenLE = UInt32(payload.count).littleEndian

        withUnsafeBytes(of: &typeLE) { src in
            for i in 0..<4 { header[i] = src[i] }
        }
        withUnsafeBytes(of: &lenLE) { src in
            for i in 0..<4 { header[4 + i] = src[i] }
        }

        writeAll(fd: socketFD, data: header)
        if !payload.isEmpty {
            writeAll(fd: socketFD, data: payload)
        }
    }

    // MARK: - Message Handlers

    /// Handles PCM_INPUT from host: writes captured audio into the shared
    /// input ring buffer for the HAL plugin to read on its RT thread.
    /// We are the producer of the input ring; the plugin is the consumer.
    private func handlePCMInput(payload: [UInt8]) {
        guard !payload.isEmpty, let base = shmBase else { return }

        // Interpret payload as Float32 samples.
        let sampleCount = payload.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }

        let wPtr = base.advanced(by: Self.offInputWritePos)
            .assumingMemoryBound(to: UInt64.self)
        let rPtr = base.advanced(by: Self.offInputReadPos)
            .assumingMemoryBound(to: UInt64.self)

        let w = atomicLoadU64Relaxed(wPtr)
        let r = atomicLoadU64Acquire(rPtr)

        let space = SHM_RING_SAMPLES - Int(UInt32(truncatingIfNeeded: w &- r))
        let toWrite = min(sampleCount, space)
        guard toWrite > 0 else { return }

        let bufferBase = base.advanced(by: Self.offInputBuffer)
            .assumingMemoryBound(to: Float.self)

        payload.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Float.self) else { return }

            let startIdx = Int(w & SHM_RING_MASK)
            let firstChunk = min(toWrite, SHM_RING_SAMPLES - startIdx)
            let secondChunk = toWrite - firstChunk

            memcpy(bufferBase.advanced(by: startIdx),
                   src,
                   firstChunk * MemoryLayout<Float>.size)
            if secondChunk > 0 {
                memcpy(bufferBase,
                       src.advanced(by: firstChunk),
                       secondChunk * MemoryLayout<Float>.size)
            }
        }

        // Advance the write position (release so the consumer sees the data).
        atomicStoreU64Release(wPtr, w &+ UInt64(toWrite))
    }

    /// Handles LATENCY_REPLY from host.
    private func handleLatencyReply(payload: [UInt8]) {
        guard payload.count >= 4 else { return }
        let bufferFrames = payload.withUnsafeBytes { buf -> UInt32 in
            UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let latencyMs = Double(bufferFrames) / Double(format.sampleRate) * 1000.0
        logVerbose("Host reports buffer latency: \(bufferFrames) frames "
            + "(~\(String(format: "%.1f", latencyMs))ms)")
    }

    // MARK: - Shared Memory

    /// Attaches to the HAL plugin's shared memory segment. Waits up to
    /// `SHM_ATTACH_TIMEOUT` for the plugin to create the segment.
    ///
    /// - Returns: `true` if the segment was successfully mapped and validated.
    private func attachSharedMemory() -> Bool {
        let deadline = Date().addingTimeInterval(SHM_ATTACH_TIMEOUT)

        while Date() < deadline && shouldRun {
            let fd = vortex_shm_open(SHM_NAME, O_RDWR, 0)
            if fd >= 0 {
                // Compute the expected size. We need to match VortexSharedAudio.h.
                // The struct has header fields + two ring buffers of float samples.
                let expectedSize = Self.offInputBuffer
                    + (SHM_RING_SAMPLES * MemoryLayout<Float>.size)

                let mapped = mmap(nil, expectedSize,
                                  PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
                if mapped == MAP_FAILED {
                    logVerbose("mmap failed: errno \(errno) (\(errnoString()))")
                    close(fd)
                    usleep(SHM_ATTACH_POLL_INTERVAL)
                    continue
                }

                // Validate magic and version.
                let base = mapped!
                let magic = base.load(fromByteOffset: Self.offMagic, as: UInt32.self)
                let version = base.load(fromByteOffset: Self.offVersion, as: UInt32.self)

                if magic != SHM_MAGIC || version != SHM_VERSION {
                    logVerbose("Shared memory validation failed: magic=0x\(String(magic, radix: 16)), "
                        + "version=\(version) (expected magic=0x\(String(SHM_MAGIC, radix: 16)), "
                        + "version=\(SHM_VERSION))")
                    munmap(mapped, expectedSize)
                    close(fd)
                    usleep(SHM_ATTACH_POLL_INTERVAL)
                    continue
                }

                self.sharedState = mapped!.assumingMemoryBound(to: UInt8.self)
                self.shmMappedSize = expectedSize
                self.shmFD = fd
                return true
            }

            // shm_open failed -- plugin hasn't created it yet.
            usleep(SHM_ATTACH_POLL_INTERVAL)
        }

        return false
    }

    /// Detaches from shared memory.
    private func detachSharedMemory() {
        if let state = sharedState {
            munmap(state, shmMappedSize)
            sharedState = nil
            shmMappedSize = 0
        }
        if shmFD >= 0 {
            close(shmFD)
            shmFD = -1
        }
    }

    /// Reads the `isActive` flag from shared memory.
    private func shmIsActive() -> Bool {
        guard let base = shmBase else { return false }
        let ptr = base.advanced(by: Self.offIsActive)
            .assumingMemoryBound(to: UInt32.self)
        return atomicLoadU32Acquire(ptr) != 0
    }

    /// Updates the daemon's format from the shared memory state.
    private func updateFormatFromShm() {
        guard let base = shmBase else { return }
        let sr = base.load(fromByteOffset: Self.offSampleRate, as: UInt32.self)
        let ch = base.load(fromByteOffset: Self.offChannels, as: UInt32.self)
        if sr > 0 {
            format.sampleRate = sr
        }
        if ch > 0 {
            format.channels = ch
        }
    }

    /// Checks if the sample rate changed in shared memory and re-sends
    /// CONFIGURE to the host if so.
    private func checkForSampleRateChange() {
        guard let base = shmBase else { return }
        let sr = base.load(fromByteOffset: Self.offSampleRate, as: UInt32.self)
        if sr > 0 && sr != format.sampleRate {
            logVerbose("Sample rate changed: \(format.sampleRate) -> \(sr)")
            format.sampleRate = sr
            sendConfigure()
        }
    }

    // MARK: - Atomic Helpers (Swift wrappers around C11 atomics via Darwin)

    // Swift does not have direct C11 atomic intrinsics, but we can use
    // OSAtomic or direct load/store since we are on arm64 where aligned
    // 32/64-bit loads and stores are naturally atomic. We use the Darwin
    // memory barrier intrinsics for ordering.

    private func atomicLoadU64Acquire(_ ptr: UnsafeMutablePointer<UInt64>) -> UInt64 {
        // On arm64, a plain load + dmb ld gives acquire semantics.
        // In practice, Swift's pointer load is sequentially consistent for
        // naturally aligned values on arm64, but we add an explicit barrier.
        let value = ptr.pointee
        OSMemoryBarrier()
        return value
    }

    private func atomicLoadU64Relaxed(_ ptr: UnsafeMutablePointer<UInt64>) -> UInt64 {
        return ptr.pointee
    }

    private func atomicStoreU64Release(_ ptr: UnsafeMutablePointer<UInt64>, _ value: UInt64) {
        OSMemoryBarrier()
        ptr.pointee = value
    }

    private func atomicLoadU32Acquire(_ ptr: UnsafeMutablePointer<UInt32>) -> UInt32 {
        let value = ptr.pointee
        OSMemoryBarrier()
        return value
    }

    // MARK: - POSIX I/O Helpers

    /// Reads exactly `count` bytes from a file descriptor, handling partial reads.
    private func readExactly(
        fd: Int32,
        buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int {
        var totalRead = 0
        while totalRead < count {
            let n = read(fd, buffer.advanced(by: totalRead), count - totalRead)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { continue }
                break
            }
            totalRead += n
        }
        return totalRead
    }

    /// Variant that reads into an Array<UInt8>.
    private func readExactly(
        fd: Int32,
        buffer: inout [UInt8],
        count: Int
    ) -> Int {
        buffer.withUnsafeMutableBufferPointer { buf in
            readExactly(fd: fd, buffer: buf.baseAddress!, count: count)
        }
    }

    /// Writes all bytes to a file descriptor, handling partial writes.
    private func writeAll(fd: Int32, data: [UInt8]) {
        data.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < data.count {
                let n = write(fd, base.advanced(by: totalWritten),
                              data.count - totalWritten)
                if n <= 0 {
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    break
                }
                totalWritten += n
            }
        }
    }

    // MARK: - Logging

    /// Logs a lifecycle message (always printed).
    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] VortexAudioDaemon: \(message)")
    }

    /// Logs a diagnostic message (only printed in verbose mode).
    private func logVerbose(_ message: String) {
        guard verbose else { return }
        log(message)
    }

    private func errnoString() -> String {
        String(cString: strerror(errno))
    }
}

// MARK: - AudioFormat

/// Simple audio format descriptor (guest side, no VortexCore dependency).
private struct AudioFormat {
    var sampleRate: UInt32
    var channels: UInt32
    var bitsPerSample: UInt32
    var isFloat: Bool

    var bytesPerFrame: Int {
        Int(channels) * Int(bitsPerSample / 8)
    }
}

// MARK: - Entry Point

@main
enum VortexAudioDaemonMain {
    static func main() {
        // Parse command-line arguments for optional format override.
        var sampleRate = DEFAULT_SAMPLE_RATE
        var channels = DEFAULT_CHANNELS
        var bitsPerSample = DEFAULT_BITS_PER_SAMPLE
        var isFloat = DEFAULT_IS_FLOAT

        var verbose = false

        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--sample-rate":
                if i + 1 < args.count, let val = UInt32(args[i + 1]) {
                    sampleRate = val
                    i += 1
                }
            case "--channels":
                if i + 1 < args.count, let val = UInt32(args[i + 1]) {
                    channels = val
                    i += 1
                }
            case "--bits":
                if i + 1 < args.count, let val = UInt32(args[i + 1]) {
                    bitsPerSample = val
                    i += 1
                }
            case "--int16":
                isFloat = false
                bitsPerSample = 16
            case "--host":
                if i + 1 < args.count {
                    hostAddress = args[i + 1]
                    i += 1
                }
            case "--verbose", "-v":
                verbose = true
            case "--help":
                print("""
                    VortexAudioDaemon — Guest-side audio transport for Vortex VMM.

                    Options:
                      --sample-rate <Hz>   Sample rate (default: 48000)
                      --channels <N>       Channel count (default: 2)
                      --bits <N>           Bits per sample (default: 32)
                      --int16              Use 16-bit signed integer format
                      --host <ip>          Host bridge IP (default: 192.168.64.1)
                      --verbose, -v        Enable verbose diagnostic logging
                      --help               Show this help message
                    """)
                return
            default:
                break
            }
            i += 1
        }

        let daemon = VortexAudioDaemon(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            isFloat: isFloat
        )
        daemon.verbose = verbose
        daemon.run()
    }
}
