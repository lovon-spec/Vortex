// VsockAudioBridge.swift — Host-side vsock audio server.
// VortexVZ
//
// Bridges audio between a macOS guest and host CoreAudio. The guest runs a
// daemon that connects over VZVirtioSocketDevice (vsock) and sends/receives
// raw PCM frames. This bridge feeds PCM into the existing AudioRouter/
// AudioRingBuffer pipeline, giving us per-VM device routing that VZ's
// built-in audio path cannot provide.
//
// Wire protocol:
//   [4 bytes: message type (UInt32 LE)]
//   [4 bytes: payload length (UInt32 LE)]
//   [N bytes: payload]
//
// Message types:
//   0x01 CONFIGURE      guest -> host: audio format info
//   0x02 PCM_OUTPUT     guest -> host: playback PCM data
//   0x03 PCM_INPUT      host -> guest: capture PCM data
//   0x04 START          guest -> host: IO started
//   0x05 STOP           guest -> host: IO stopped
//   0x06 LATENCY_QUERY  guest -> host: round-trip latency query
//   0x07 LATENCY_REPLY  host -> guest: latency response

import Darwin
import Foundation
import Virtualization
import VortexAudio
import VortexCore

// MARK: - VsockAudioMessage

/// Message types exchanged over the vsock audio channel.
public enum VsockAudioMessageType: UInt32, Sendable {
    case configure    = 0x01
    case pcmOutput    = 0x02
    case pcmInput     = 0x03
    case start        = 0x04
    case stop         = 0x05
    case latencyQuery = 0x06
    case latencyReply = 0x07
}

// MARK: - VsockAudioFormat

/// Audio format negotiated via the CONFIGURE message.
///
/// Sent by the guest daemon at connection time to tell the host what
/// PCM format it will produce/consume.
public struct VsockAudioFormat: Sendable, Equatable {
    /// Sample rate in Hz (e.g. 44100, 48000).
    public var sampleRate: UInt32

    /// Number of channels (e.g. 1 for mono, 2 for stereo).
    public var channels: UInt32

    /// Bits per sample (e.g. 16 for Int16, 32 for Float32).
    public var bitsPerSample: UInt32

    /// Whether samples are IEEE 754 floating-point (true) or signed integer (false).
    public var isFloat: Bool

    /// Size of the serialized wire representation in bytes.
    public static let wireSize: Int = 13 // 4 + 4 + 4 + 1

    public init(
        sampleRate: UInt32 = 48000,
        channels: UInt32 = 2,
        bitsPerSample: UInt32 = 32,
        isFloat: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.isFloat = isFloat
    }

    /// Bytes per frame (channels * bytesPerSample).
    public var bytesPerFrame: Int {
        Int(channels) * Int(bitsPerSample / 8)
    }

    // MARK: - Wire serialization

    /// Serializes the format to a Data blob for the CONFIGURE message payload.
    public func serialize() -> Data {
        var data = Data(capacity: Self.wireSize)
        var sr = sampleRate.littleEndian
        var ch = channels.littleEndian
        var bps = bitsPerSample.littleEndian
        let fl: UInt8 = isFloat ? 1 : 0

        withUnsafeBytes(of: &sr) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &bps) { data.append(contentsOf: $0) }
        data.append(fl)

        return data
    }

    /// Deserializes a format from a CONFIGURE message payload.
    ///
    /// - Parameter data: The payload data (must be at least `wireSize` bytes).
    /// - Returns: The parsed format, or `nil` if the data is too short.
    public static func deserialize(from data: Data) -> VsockAudioFormat? {
        guard data.count >= wireSize else { return nil }

        let sr = data.withUnsafeBytes { buf -> UInt32 in
            buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }
        let ch = data.withUnsafeBytes { buf -> UInt32 in
            buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }
        let bps = data.withUnsafeBytes { buf -> UInt32 in
            buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        }
        let fl = data[12]

        return VsockAudioFormat(
            sampleRate: UInt32(littleEndian: sr),
            channels: UInt32(littleEndian: ch),
            bitsPerSample: UInt32(littleEndian: bps),
            isFloat: fl != 0
        )
    }
}

// MARK: - VsockAudioBridge

/// Host-side vsock audio server that bridges a VM's audio over
/// `VZVirtioSocketDevice` to the CoreAudio `AudioRouter` pipeline.
///
/// Usage:
/// ```swift
/// let bridge = VsockAudioBridge(vmID: config.id)
/// try bridge.attach(to: vm, audioConfig: config.audio)
/// // ... VM runs, guest daemon connects ...
/// bridge.detach()
/// ```
///
/// **Threading model:**
/// - `attach()` / `detach()` must be called from the main thread.
/// - The vsock read loop runs on a dedicated DispatchQueue.
/// - PCM data flows through the AudioRingBuffer (lock-free SPSC), which
///   is read by the CoreAudio render callback on its real-time thread.
/// - The input capture path writes from the CoreAudio callback into a
///   separate ring buffer, read by the vsock write loop on its queue.
public final class VsockAudioBridge: @unchecked Sendable {

    // MARK: - Constants

    /// Well-known vsock port for Vortex audio transport.
    public static let audioPort: UInt32 = 5198

    /// Size of the message header: type (4 bytes) + length (4 bytes).
    private static let headerSize = 8

    /// Maximum payload size to accept (8 MB — generous for audio buffers).
    private static let maxPayloadSize: UInt32 = 8 * 1024 * 1024

    /// Interval for the input capture send timer (5 ms ~ 200 fps).
    private static let inputSendInterval: TimeInterval = 0.005

    // MARK: - Properties

    /// The Vortex VM ID this bridge serves.
    public let vmID: UUID

    /// The AudioRouter managing per-VM CoreAudio units.
    /// Fully qualified to avoid ambiguity with VortexCore.AudioRouter protocol.
    private var router: VortexAudio.AudioRouter?

    /// The negotiated audio format from the guest.
    public private(set) var negotiatedFormat: VsockAudioFormat?

    /// Whether the bridge is currently attached to a VM.
    public private(set) var isAttached: Bool = false

    /// Whether the guest has signaled IO is active.
    public private(set) var isStreaming: Bool = false

    /// The active vsock connection from the guest.
    private var connection: VZVirtioSocketConnection?

    /// The vsock device we are listening on.
    private weak var socketDevice: VZVirtioSocketDevice?

    /// Dispatch queue for the vsock read loop.
    private let readQueue = DispatchQueue(
        label: "com.vortex.vsock-audio.read",
        qos: .userInteractive
    )

    /// Dispatch queue for sending input (capture) data to the guest.
    private let writeQueue = DispatchQueue(
        label: "com.vortex.vsock-audio.write",
        qos: .userInteractive
    )

    /// Timer source for periodically sending captured input PCM to the guest.
    private var inputSendTimer: DispatchSourceTimer?

    /// Scratch buffer for reading PCM from the input ring buffer.
    /// Pre-allocated to avoid RT allocations.
    private var inputScratchBuffer: UnsafeMutablePointer<Float>?
    private var inputScratchCapacity: Int = 0

    /// The audio config from the Vortex VM configuration.
    private var audioConfig: AudioConfig?

    /// Retains the VZ socket listener and its delegate for the lifetime
    /// of the bridge. Without this, the listener delegate would be released.
    private var vsockListener: VZVirtioSocketListener?
    private var vsockListenerDelegate: VsockAudioListenerDelegate?

    // MARK: - Init

    /// Creates a bridge for a specific VM.
    ///
    /// - Parameter vmID: The unique identifier of the VM this bridge serves.
    public init(vmID: UUID) {
        self.vmID = vmID
    }

    deinit {
        detach()
    }

    // MARK: - Attach / Detach

    /// Attaches the bridge to a running VM's vsock device and begins
    /// listening for guest audio connections.
    ///
    /// - Parameters:
    ///   - vm: The running VZ virtual machine.
    ///   - audioConfig: The per-VM audio routing configuration.
    /// - Throws: `VortexError` if the VM has no vsock device or audio is disabled.
    public func attach(to vm: VZVirtualMachine, audioConfig: AudioConfig) throws {
        guard audioConfig.enabled else {
            return // Nothing to do — audio is disabled.
        }

        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw VortexError.deviceConfigurationFailed(
                device: "VZVirtioSocketDevice",
                reason: "No vsock device found on the VM."
            )
        }

        self.audioConfig = audioConfig
        self.socketDevice = device

        // Set up the VZ vsock listener for incoming guest connections.
        let delegate = VsockAudioListenerDelegate(bridge: self)
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        device.setSocketListener(listener, forPort: Self.audioPort)
        self.vsockListener = listener
        self.vsockListenerDelegate = delegate

        // Also start a TCP listener on the same port as fallback.
        // macOS guests may not support AF_VSOCK from userspace.
        startTCPListener()

        isAttached = true
    }

    /// TCP server socket for fallback transport.
    private var tcpListenFD: Int32 = -1
    private var tcpListenSource: DispatchSourceRead?

    /// Starts a TCP listener on port 5198 bound to 0.0.0.0.
    private func startTCPListener() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[audio-tcp] Failed to create socket: errno \(errno)")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(Self.audioPort).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            print("[audio-tcp] bind() failed: errno \(errno)")
            Darwin.close(fd)
            return
        }

        guard listen(fd, 2) == 0 else {
            print("[audio-tcp] listen() failed: errno \(errno)")
            Darwin.close(fd)
            return
        }

        print("[audio-tcp] Listening on TCP port \(Self.audioPort)")
        self.tcpListenFD = fd

        // Accept connections on a dispatch source.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLen)
                }
            }
            guard clientFD >= 0 else { return }

            // Disable Nagle for low latency.
            var noDelay: Int32 = 1
            setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            print("[audio-tcp] Guest daemon connected via TCP")
            self.handleTCPConnection(fd: clientFD)
        }
        source.resume()
        self.tcpListenSource = source
    }

    /// Detaches the bridge, closing any active connection and releasing
    /// CoreAudio resources.
    public func detach() {
        isStreaming = false

        inputSendTimer?.cancel()
        inputSendTimer = nil

        if let scratch = inputScratchBuffer {
            scratch.deallocate()
            inputScratchBuffer = nil
            inputScratchCapacity = 0
        }

        router?.stop()
        router = nil

        if let conn = connection {
            Darwin.close(conn.fileDescriptor)
            connection = nil
        }

        if tcpClientFD >= 0 {
            Darwin.close(tcpClientFD)
            tcpClientFD = -1
        }

        tcpListenSource?.cancel()
        tcpListenSource = nil
        if tcpListenFD >= 0 {
            Darwin.close(tcpListenFD)
            tcpListenFD = -1
        }

        vsockListener = nil
        vsockListenerDelegate = nil
        socketDevice = nil
        audioConfig = nil
        negotiatedFormat = nil
        isAttached = false
    }

    // MARK: - Connection Handling

    /// Called by the listener when a guest daemon connects.
    ///
    /// Sets up the read loop to process messages from the guest.
    fileprivate func handleNewConnection(_ conn: VZVirtioSocketConnection) {
        // If there's an existing connection, close it (guest daemon restarted).
        if let old = connection {
            Darwin.close(old.fileDescriptor)
            router?.stop()
            router = nil
            isStreaming = false
            negotiatedFormat = nil
        }

        self.connection = conn

        // Start the read loop on a dedicated queue.
        readQueue.async { [weak self] in
            self?.readLoop(connection: conn)
        }
    }

    /// Called when a guest daemon connects via TCP fallback.
    fileprivate func handleTCPConnection(fd: Int32) {
        // If there's an existing connection, close it.
        if let old = connection {
            Darwin.close(old.fileDescriptor)
            router?.stop()
            router = nil
            isStreaming = false
            negotiatedFormat = nil
        }
        if tcpClientFD >= 0 {
            Darwin.close(tcpClientFD)
            router?.stop()
            router = nil
            isStreaming = false
            negotiatedFormat = nil
        }

        self.tcpClientFD = fd
        self.connection = nil

        readQueue.async { [weak self] in
            self?.readLoopFD(fd: fd)
        }
    }

    /// Raw TCP client file descriptor (when using TCP fallback).
    private var tcpClientFD: Int32 = -1

    // MARK: - Read Loop

    /// Main read loop for VZ vsock connections.
    private func readLoop(connection conn: VZVirtioSocketConnection) {
        readLoopFD(fd: conn.fileDescriptor)
    }

    /// Main read loop that processes incoming messages from the guest.
    ///
    /// Runs on `readQueue` until the connection closes or an error occurs.
    private func readLoopFD(fd: Int32) {
        let fd = fd

        while true {
            // Read the 8-byte header.
            var headerBuf = [UInt8](repeating: 0, count: Self.headerSize)
            let headerRead = readExactlyFromFD(fd, buffer: &headerBuf, count: Self.headerSize)
            guard headerRead == Self.headerSize else {
                // Connection closed or read error.
                handleDisconnect()
                return
            }

            // Parse header.
            let rawType = headerBuf.withUnsafeBytes { buf -> UInt32 in
                buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            }
            let payloadLength = headerBuf.withUnsafeBytes { buf -> UInt32 in
                buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            }

            let msgTypeValue = UInt32(littleEndian: rawType)
            let payloadLen = UInt32(littleEndian: payloadLength)

            // Sanity check payload size.
            guard payloadLen <= Self.maxPayloadSize else {
                handleDisconnect()
                return
            }

            // Read payload.
            var payload = Data()
            if payloadLen > 0 {
                var payloadBuf = [UInt8](repeating: 0, count: Int(payloadLen))
                let payloadRead = readExactlyFromFD(
                    fd, buffer: &payloadBuf, count: Int(payloadLen)
                )
                guard payloadRead == Int(payloadLen) else {
                    handleDisconnect()
                    return
                }
                payload = Data(payloadBuf)
            }

            // Dispatch by message type.
            guard let msgType = VsockAudioMessageType(rawValue: msgTypeValue) else {
                // Unknown message type — skip it.
                continue
            }

            switch msgType {
            case .configure:
                print("[audio-tcp] Received CONFIGURE (\(payload.count) bytes)")
                handleConfigure(payload: payload)
            case .pcmOutput:
                handlePCMOutput(payload: payload)
            case .start:
                print("[audio-tcp] Received START")
                handleStart()
            case .stop:
                print("[audio-tcp] Received STOP")
                handleStop()
            case .latencyQuery:
                handleLatencyQuery()
            case .pcmInput, .latencyReply:
                // These are host -> guest messages; ignore if received.
                break
            }
        }
    }

    /// Reads exactly `count` bytes from a POSIX file descriptor,
    /// handling partial reads and EINTR.
    ///
    /// - Returns: The number of bytes actually read. Less than `count`
    ///   indicates EOF or an unrecoverable error.
    private func readExactlyFromFD(
        _ fd: Int32,
        buffer: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int {
        var totalRead = 0
        while totalRead < count {
            let n = Darwin.read(fd, buffer.advanced(by: totalRead), count - totalRead)
            if n > 0 {
                totalRead += n
            } else if n == 0 {
                break // EOF
            } else {
                if errno == EINTR { continue }
                break // Error
            }
        }
        return totalRead
    }

    /// Variant that reads into an Array<UInt8>.
    private func readExactlyFromFD(
        _ fd: Int32,
        buffer: inout [UInt8],
        count: Int
    ) -> Int {
        buffer.withUnsafeMutableBufferPointer { buf in
            readExactlyFromFD(fd, buffer: buf.baseAddress!, count: count)
        }
    }

    // MARK: - Message Handlers

    /// Handles the CONFIGURE message: sets up the AudioRouter with the
    /// negotiated format.
    private func handleConfigure(payload: Data) {
        guard let format = VsockAudioFormat.deserialize(from: payload) else {
            return
        }
        self.negotiatedFormat = format

        // Set up the AudioRouter with the negotiated parameters.
        guard let audioConfig = self.audioConfig else { return }

        let newRouter = VortexAudio.AudioRouter(vmID: vmID.uuidString)
        newRouter.sampleRate = Float64(format.sampleRate)
        newRouter.channelCount = format.channels
        newRouter.bitDepth = format.bitsPerSample

        do {
            try newRouter.configure(
                output: audioConfig.output,
                input: audioConfig.input
            )
            print("[audio-tcp] AudioRouter configured: \(format.sampleRate)Hz, \(format.channels)ch, \(format.bitsPerSample)bit")
        } catch {
            print("[audio-tcp] AudioRouter configure FAILED: \(error)")
            return
        }

        // Replace the previous router.
        router?.stop()
        self.router = newRouter

        // Pre-allocate the input scratch buffer for the capture send loop.
        if audioConfig.input != nil {
            let scratchFrames = 1024
            let scratchSamples = scratchFrames * Int(format.channels)
            if let old = inputScratchBuffer { old.deallocate() }
            inputScratchBuffer = .allocate(capacity: scratchSamples)
            inputScratchBuffer?.initialize(repeating: 0.0, count: scratchSamples)
            inputScratchCapacity = scratchSamples
        }
    }

    /// Handles the START message: begins audio streaming.
    private func handleStart() {
        guard let router = self.router else { return }

        do {
            try router.start()
            isStreaming = true
            print("[audio-tcp] AudioRouter started, streaming=true")

            // If input is configured, start the periodic send timer.
            if let rb = router.inputRingBuffer {
                print("[audio-tcp] Input ring buffer available (capacity: \(rb.capacity) samples), starting input capture timer")
                print("[audio-tcp] Input unit running: \(router.inputUnit?.isRunning ?? false)")
                startInputSendTimer()
            } else {
                print("[audio-tcp] No input ring buffer — input capture disabled")
            }
        } catch {
            print("[audio-tcp] AudioRouter start FAILED: \(error)")
        }
    }

    /// Handles the STOP message: pauses audio streaming.
    private func handleStop() {
        isStreaming = false
        inputSendTimer?.cancel()
        inputSendTimer = nil
        router?.stop()
    }

    private var pcmOutputCount: UInt64 = 0

    /// Handles PCM_OUTPUT: guest playback data.
    ///
    /// Writes the raw PCM bytes into the output ring buffer, which the
    /// CoreAudio render callback reads from.
    private func handlePCMOutput(payload: Data) {
        pcmOutputCount += 1
        if pcmOutputCount <= 5 || pcmOutputCount % 100 == 0 {
            print("[audio-tcp] PCM_OUTPUT #\(pcmOutputCount): \(payload.count) bytes")
        }

        guard isStreaming,
              let ringBuffer = router?.outputRingBuffer,
              let format = negotiatedFormat else {
            if pcmOutputCount <= 3 {
                print("[audio-tcp] PCM_OUTPUT dropped: streaming=\(isStreaming), router=\(router != nil), format=\(negotiatedFormat != nil)")
            }
            return
        }

        let bytesPerSample = Int(format.bitsPerSample / 8)
        let bytesPerFrame = Int(format.channels) * bytesPerSample

        guard bytesPerFrame > 0 else { return }

        let frameCount = payload.count / bytesPerFrame
        guard frameCount > 0 else { return }

        // The ring buffer expects Float32 interleaved samples.
        // If the guest sends Float32, we can write directly.
        // If the guest sends Int16, we need to convert.
        if format.isFloat && format.bitsPerSample == 32 {
            // Direct path: Float32 PCM.
            payload.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let floatPtr = base.assumingMemoryBound(to: Float.self)
                let sampleCount = frameCount * Int(format.channels)
                let srcBuf = UnsafeBufferPointer(start: floatPtr, count: sampleCount)
                ringBuffer.write(srcBuf, frameCount: frameCount)
            }
        } else if !format.isFloat && format.bitsPerSample == 16 {
            // Int16 -> Float32 conversion.
            let sampleCount = frameCount * Int(format.channels)
            payload.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let int16Ptr = base.assumingMemoryBound(to: Int16.self)

                // Use a stack-allocated buffer for small payloads,
                // otherwise allocate on the heap.
                let floatBuf = UnsafeMutablePointer<Float>.allocate(
                    capacity: sampleCount
                )
                defer { floatBuf.deallocate() }

                for i in 0..<sampleCount {
                    floatBuf[i] = Float(int16Ptr[i]) / 32768.0
                }

                let srcBuf = UnsafeBufferPointer(start: floatBuf, count: sampleCount)
                ringBuffer.write(srcBuf, frameCount: frameCount)
            }
        }
        // Other formats (e.g. 24-bit) would need additional conversion paths.
    }

    /// Handles LATENCY_QUERY: responds with the round-trip latency estimate.
    private func handleLatencyQuery() {
        // Estimate latency: ring buffer size / sample rate gives the buffer
        // latency. Double it for round-trip.
        guard let format = negotiatedFormat else { return }

        let bufferFrames: UInt32
        if let rb = router?.outputRingBuffer {
            bufferFrames = UInt32(rb.capacity / rb.channelCount)
        } else {
            bufferFrames = UInt32(format.sampleRate / 10) // ~100ms fallback
        }

        // Latency reply payload: [4 bytes: buffer frames (UInt32 LE)]
        // The guest can compute latency as bufferFrames / sampleRate.
        var payload = Data(capacity: 4)
        var frames = bufferFrames.littleEndian
        withUnsafeBytes(of: &frames) { payload.append(contentsOf: $0) }

        sendMessage(type: .latencyReply, payload: payload)
    }

    /// Called when the guest connection drops (daemon exit, guest reboot).
    private func handleDisconnect() {
        isStreaming = false
        inputSendTimer?.cancel()
        inputSendTimer = nil
        router?.stop()
        connection = nil
        negotiatedFormat = nil
    }

    // MARK: - Input Capture (host -> guest)

    /// Starts a periodic timer that reads captured audio from the input
    /// ring buffer and sends it to the guest as PCM_INPUT messages.
    private func startInputSendTimer() {
        inputSendTimer?.cancel()

        print("[audio-tcp] Creating input timer on writeQueue...")
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.inputSendInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self else {
                print("[audio-tcp] Input timer: self is nil (bridge deallocated)")
                return
            }
            self.sendInputCapture()
        }
        timer.resume()
        self.inputSendTimer = timer
        print("[audio-tcp] Input timer started and resumed")
    }

    private var inputCaptureCount: UInt64 = 0

    /// Reads available captured audio from the input ring buffer and
    /// sends it to the guest.
    private func sendInputCapture() {
        inputCaptureCount += 1
        if inputCaptureCount <= 5 || inputCaptureCount % 500 == 0 {
            print("[audio-tcp] Input poll #\(inputCaptureCount): streaming=\(isStreaming), router=\(router != nil), format=\(negotiatedFormat != nil), scratch=\(inputScratchBuffer != nil), inputRB=\(router?.inputRingBuffer != nil)")
        }

        guard isStreaming,
              let ringBuffer = router?.inputRingBuffer,
              let format = negotiatedFormat,
              let scratch = inputScratchBuffer else {
            return
        }

        let available = ringBuffer.framesAvailableForRead
        if inputCaptureCount <= 5 || (available > 0 && inputCaptureCount % 100 == 0) {
            print("[audio-tcp] Input avail: \(available) frames")
        }
        guard available > 0 else { return }

        // Read up to what we have scratch space for.
        let maxFrames = inputScratchCapacity / Int(format.channels)
        let framesToRead = min(available, maxFrames)
        guard framesToRead > 0 else { return }

        let sampleCount = framesToRead * Int(format.channels)
        let dest = UnsafeMutableBufferPointer(start: scratch, count: sampleCount)
        let framesRead = ringBuffer.read(dest, frameCount: framesToRead)
        guard framesRead > 0 else { return }

        let samplesRead = framesRead * Int(format.channels)

        // Build the payload.
        if format.isFloat && format.bitsPerSample == 32 {
            // Direct path: send Float32 PCM bytes.
            let byteCount = samplesRead * MemoryLayout<Float>.size
            let payload = Data(
                bytesNoCopy: UnsafeMutableRawPointer(scratch),
                count: byteCount,
                deallocator: .none
            )
            sendMessage(type: .pcmInput, payload: payload)
        } else if !format.isFloat && format.bitsPerSample == 16 {
            // Float32 -> Int16 conversion.
            let int16Buf = UnsafeMutablePointer<Int16>.allocate(capacity: samplesRead)
            defer { int16Buf.deallocate() }

            for i in 0..<samplesRead {
                let clamped = max(-1.0, min(1.0, scratch[i]))
                int16Buf[i] = Int16(clamped * 32767.0)
            }

            let byteCount = samplesRead * MemoryLayout<Int16>.size
            let payload = Data(
                bytesNoCopy: UnsafeMutableRawPointer(int16Buf),
                count: byteCount,
                deallocator: .none
            )
            sendMessage(type: .pcmInput, payload: payload)
        }
    }

    // MARK: - Message Sending

    /// Sends a message to the guest over the vsock connection.
    ///
    /// - Parameters:
    ///   - type: The message type.
    ///   - payload: The message payload (may be empty).
    private func sendMessage(type: VsockAudioMessageType, payload: Data) {
        guard let conn = connection else { return }
        let fd = conn.fileDescriptor

        var header = Data(capacity: Self.headerSize)
        var typeLE = type.rawValue.littleEndian
        var lengthLE = UInt32(payload.count).littleEndian

        withUnsafeBytes(of: &typeLE) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &lengthLE) { header.append(contentsOf: $0) }

        writeAllToFD(fd, data: header)
        if !payload.isEmpty {
            writeAllToFD(fd, data: payload)
        }
    }

    /// Writes all bytes in `data` to a POSIX file descriptor, handling
    /// partial writes and EINTR.
    private func writeAllToFD(_ fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var totalWritten = 0
            let count = rawBuf.count
            while totalWritten < count {
                let n = Darwin.write(
                    fd,
                    base.advanced(by: totalWritten),
                    count - totalWritten
                )
                if n > 0 {
                    totalWritten += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    break // Unrecoverable write error.
                } else {
                    break
                }
            }
        }
    }
}

// MARK: - VsockAudioListenerDelegate

/// VZ socket listener delegate that accepts incoming guest connections
/// for the audio bridge.
private final class VsockAudioListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {

    private weak var bridge: VsockAudioBridge?

    init(bridge: VsockAudioBridge) {
        self.bridge = bridge
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        bridge?.handleNewConnection(connection)
        return true
    }
}
