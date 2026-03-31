// VirtioSound.swift — Virtio 1.2 Sound Device (Section 5.14).
// VortexDevices
//
// Implements the OASIS Virtio v1.2 sound device (virtio-snd), providing
// bidirectional PCM audio between the guest and per-VM CoreAudio routing.
// This is the core differentiator of Vortex: each VM gets independent
// audio device routing without touching host default device settings.
//
// PCI Identity:
//   Vendor ID:         0x1AF4
//   Device ID:         0x1059  (0x1040 + 25, non-transitional modern)
//   Subsystem Vendor:  0x1AF4
//   Subsystem ID:      0x0019  (device type 25)
//   Revision ID:       1
//   Class Code:        0x040100 (Multimedia audio controller)
//
// Virtqueues:
//   0: controlq  — guest->host control messages (info queries, stream mgmt)
//   1: eventq    — host->guest asynchronous event notifications
//   2: txq       — guest->host PCM playback data
//   3: rxq       — host->guest PCM capture data
//
// The device advertises 2 PCM streams (1 output, 1 input), 0 jacks, 0 chmaps.
// macOS guests use Apple's in-box AppleVirtIOSound driver which matches the
// standard virtio-snd PCI identity (vendor 0x1AF4, device 0x1059).
//
// Threading model:
//   - Control/event queue processing: vCPU exit handler thread (via notification)
//   - TX queue processing: vCPU thread -> writes PCM to AudioRingBuffer
//   - RX queue processing: vCPU thread -> reads PCM from AudioRingBuffer
//   - AudioUnit callbacks: CoreAudio real-time thread (RT-safe, no locks)
//   - The AudioRingBuffer is the SPSC bridge between vCPU and audio threads.

import Foundation
import VortexCore
import VortexAudio

// MARK: - Virtio Sound Constants (Virtio 1.2, Section 5.14)
// Verified against linux/include/uapi/linux/virtio_snd.h

/// Virtio sound device feature bits.
public enum VirtioSoundFeature {
    /// Device supports control elements (VIRTIO_SND_F_CTLS).
    /// Not implemented in v1; reserved for future use.
    public static let ctls: UInt64 = 1 << 0
}

// MARK: Request Codes

/// Control request codes for the controlq (Virtio 1.2, Section 5.14.6).
///
/// Ranges: Jack 1-99, PCM 0x0100-0x01FF, Channel Map 0x0200-0x02FF.
public enum VirtioSndRequestCode {
    // Jack control requests
    public static let jackInfo: UInt32        = 1
    public static let jackRemap: UInt32       = 2

    // PCM control requests
    public static let pcmInfo: UInt32         = 0x0100
    public static let pcmSetParams: UInt32    = 0x0101
    public static let pcmPrepare: UInt32      = 0x0102
    public static let pcmRelease: UInt32      = 0x0103
    public static let pcmStart: UInt32        = 0x0104
    public static let pcmStop: UInt32         = 0x0105

    // Channel map control requests
    public static let chmapInfo: UInt32       = 0x0200
}

// MARK: Status Codes

/// Response status codes (Virtio 1.2, Section 5.14.6.1).
public enum VirtioSndStatus {
    public static let ok: UInt32              = 0x8000
    public static let badMsg: UInt32          = 0x8001
    public static let notSupported: UInt32    = 0x8002
    public static let ioError: UInt32         = 0x8003
}

// MARK: Stream Direction

/// PCM stream direction (Virtio 1.2, Section 5.14.6.6.1).
public enum VirtioSndDirection: UInt8 {
    case output = 0
    case input  = 1
}

// MARK: PCM Formats

/// PCM sample format indices (Virtio 1.2, Section 5.14.6.6.1).
/// Used as bit positions in the `formats` bitmask of `virtio_snd_pcm_info`,
/// and as the `format` field value in `virtio_snd_pcm_set_params`.
public enum VirtioSndPCMFormat: UInt8, CaseIterable, Sendable {
    case imaAdpcm    = 0
    case muLaw       = 1
    case aLaw        = 2
    case s8          = 3
    case u8          = 4
    case s16         = 5
    case u16         = 6
    case s18_3       = 7
    case u18_3       = 8
    case s20_3       = 9
    case u20_3       = 10
    case s24_3       = 11
    case u24_3       = 12
    case s20         = 13
    case u20         = 14
    case s24         = 15
    case u24         = 16
    case s32         = 17
    case u32         = 18
    case float32     = 19
    case float64     = 20
    case dsdU8       = 21
    case dsdU16      = 22
    case dsdU32      = 23
    case iec958Sub   = 24

    /// Bitmask value for this format (1 << rawValue).
    public var bitmask: UInt64 { 1 << UInt64(rawValue) }

    /// Bytes per sample for this format (0 if variable/unsupported).
    public var bytesPerSample: Int {
        switch self {
        case .s8, .u8:       return 1
        case .s16, .u16:     return 2
        case .s18_3, .u18_3, .s20_3, .u20_3, .s24_3, .u24_3: return 3
        case .s20, .u20, .s24, .u24, .s32, .u32, .float32: return 4
        case .float64:       return 8
        default:             return 0
        }
    }
}

// MARK: PCM Rates

/// PCM sample rate indices (Virtio 1.2, Section 5.14.6.6.1).
/// Used as bit positions in the `rates` bitmask of `virtio_snd_pcm_info`,
/// and as the `rate` field value in `virtio_snd_pcm_set_params`.
public enum VirtioSndPCMRate: UInt8, CaseIterable, Sendable {
    case rate5512    = 0
    case rate8000    = 1
    case rate11025   = 2
    case rate16000   = 3
    case rate22050   = 4
    case rate32000   = 5
    case rate44100   = 6
    case rate48000   = 7
    case rate64000   = 8
    case rate88200   = 9
    case rate96000   = 10
    case rate176400  = 11
    case rate192000  = 12
    case rate384000  = 13

    /// Bitmask value for this rate (1 << rawValue).
    public var bitmask: UInt64 { 1 << UInt64(rawValue) }

    /// The actual sample rate in Hz.
    public var hz: Double {
        switch self {
        case .rate5512:   return 5512
        case .rate8000:   return 8000
        case .rate11025:  return 11025
        case .rate16000:  return 16000
        case .rate22050:  return 22050
        case .rate32000:  return 32000
        case .rate44100:  return 44100
        case .rate48000:  return 48000
        case .rate64000:  return 64000
        case .rate88200:  return 88200
        case .rate96000:  return 96000
        case .rate176400: return 176400
        case .rate192000: return 192000
        case .rate384000: return 384000
        }
    }
}

// MARK: - Queue Indices

/// Virtqueue indices for the virtio-snd device.
private enum VirtioSoundQueue {
    static let control = 0
    static let event   = 1
    static let tx      = 2
    static let rx      = 3
    static let count   = 4
}

// MARK: - PCM Stream State Machine

/// The state of a PCM stream (Virtio 1.2, Section 5.14.6.6.1).
///
/// State transitions:
/// ```
/// UNDEFINED --> SET_PARAMS --> PREPARED --> RUNNING
///                   ^             ^           |
///                   |             +---STOP----+
///                   +---RELEASE---+
/// ```
private enum PCMStreamState: String, Sendable {
    case undefined
    case setParams
    case prepared
    case running
}

// MARK: - PCM Stream Parameters

/// Stores the negotiated parameters for a single PCM stream.
private struct PCMStreamParams: Sendable {
    var bufferBytes: UInt32 = 0
    var periodBytes: UInt32 = 0
    var channels: UInt8 = 2
    var format: VirtioSndPCMFormat = .s16
    var rate: VirtioSndPCMRate = .rate48000
}

// MARK: - PCM Stream

/// Represents one PCM stream (output or input) with its state, parameters,
/// and reference to the AudioRouter ring buffer.
private final class PCMStream: @unchecked Sendable {
    let streamID: UInt32
    let direction: VirtioSndDirection
    var state: PCMStreamState = .undefined
    var params: PCMStreamParams = PCMStreamParams()

    /// Accumulated latency tracking (bytes written but not yet consumed by host).
    var latencyBytes: UInt32 = 0

    init(streamID: UInt32, direction: VirtioSndDirection) {
        self.streamID = streamID
        self.direction = direction
    }
}

// MARK: - Supported Format/Rate Bitmasks

/// Bitmask of PCM formats we advertise to the guest.
/// S16, S32, and FLOAT32 cover the common cases for macOS and Linux guests.
private let supportedFormatsBitmask: UInt64 =
    VirtioSndPCMFormat.s16.bitmask |
    VirtioSndPCMFormat.s32.bitmask |
    VirtioSndPCMFormat.float32.bitmask

/// Bitmask of PCM rates we advertise to the guest.
/// 44100, 48000, and 96000 cover typical use cases.
private let supportedRatesBitmask: UInt64 =
    VirtioSndPCMRate.rate44100.bitmask |
    VirtioSndPCMRate.rate48000.bitmask |
    VirtioSndPCMRate.rate96000.bitmask

// MARK: - Device Config Layout

/// Byte offsets within the device-specific configuration space.
///
/// ```c
/// struct virtio_snd_config {
///     le32 jacks;     // offset 0
///     le32 streams;   // offset 4
///     le32 chmaps;    // offset 8
///     le32 controls;  // offset 12 (only if VIRTIO_SND_F_CTLS negotiated)
/// };
/// ```
private enum SoundConfigOffset {
    static let jacks: Int    = 0
    static let streams: Int  = 4
    static let chmaps: Int   = 8
    // controls at offset 12, only present if F_CTLS negotiated. We omit it.
    static let size: Int     = 12  // Without controls field
}

// MARK: - VirtioSound

/// Virtio 1.2 Sound Device emulation.
///
/// Provides bidirectional PCM audio between the guest and the host via
/// per-VM CoreAudio routing. The guest sees a standard virtio-snd device;
/// macOS matches it with AppleVirtIOSound, Linux with `virtio_snd`.
///
/// ## Architecture
///
/// ```
/// Guest Driver
///     |
///     v
/// controlq / txq / rxq  (VirtQueue, vCPU thread)
///     |
///     v
/// VirtioSound  (this class — protocol decode, state machine)
///     |
///     v
/// AudioRingBuffer  (lock-free SPSC, bridge to RT thread)
///     |
///     v
/// AudioRouter  (CoreAudio HAL output/input units, RT callback)
///     |
///     v
/// Host Audio Device  (speakers, mic, BlackHole, etc.)
/// ```
///
/// ## Threading
///
/// All VirtQueue processing happens on the vCPU exit handler thread.
/// The AudioUnit render/capture callbacks run on a CoreAudio real-time thread.
/// The `AudioRingBuffer` is the only shared data structure between these two
/// threads, and it is lock-free SPSC — no synchronization needed.
public final class VirtioSound: VirtioDeviceBase, @unchecked Sendable {

    // MARK: - Configuration

    /// Number of PCM streams: 1 output + 1 input.
    private static let streamCount: UInt32 = 2

    /// Stream ID for the output (playback) stream.
    private static let outputStreamID: UInt32 = 0

    /// Stream ID for the input (capture) stream.
    private static let inputStreamID: UInt32 = 1

    // MARK: - State

    /// The PCM streams managed by this device.
    private var streams: [PCMStream]

    /// The per-VM audio router that owns the CoreAudio output/input units.
    private let audioRouter: VortexAudio.AudioRouter

    /// Per-VM audio configuration (device UIDs, enabled state).
    private let audioConfig: AudioConfig

    /// Pre-allocated buffer for reading guest PCM data from descriptor chains.
    /// Avoids repeated allocation on the hot path.
    /// Sized for a generous maximum period (64KB should cover all realistic cases).
    private var scratchBuffer: UnsafeMutableRawPointer

    /// Size of the scratch buffer in bytes.
    private let scratchBufferSize: Int = 65536

    // MARK: - Initialization

    /// Creates a new virtio-snd device.
    ///
    /// - Parameters:
    ///   - audioRouter: The per-VM audio router for host device access.
    ///   - audioConfig: The VM's audio configuration (device UIDs).
    public init(audioRouter: VortexAudio.AudioRouter, audioConfig: AudioConfig) {
        self.audioRouter = audioRouter
        self.audioConfig = audioConfig

        self.streams = [
            PCMStream(streamID: Self.outputStreamID, direction: .output),
            PCMStream(streamID: Self.inputStreamID, direction: .input),
        ]

        self.scratchBuffer = .allocate(byteCount: scratchBufferSize, alignment: 16)

        // Initialize base with:
        //   - deviceType: .sound (type ID 25, PCI device ID 0x1059)
        //   - 4 virtqueues (control, event, tx, rx)
        //   - VIRTIO_F_VERSION_1 (added automatically by base)
        //   - 12 bytes of device-specific config (jacks + streams + chmaps)
        //   - Queue size 256 (adequate for audio; control messages are small,
        //     TX/RX buffers are sized by the guest's period configuration)
        super.init(
            deviceType: .sound,
            numQueues: VirtioSoundQueue.count,
            deviceFeatures: 0,  // No device-specific features for v1
            configSize: SoundConfigOffset.size,
            defaultQueueSize: 256
        )
    }

    deinit {
        scratchBuffer.deallocate()
    }

    // MARK: - Device Configuration Space (read-only)

    /// Read from the device-specific configuration space.
    ///
    /// Returns the `virtio_snd_config` fields:
    /// - jacks: 0 (no physical jacks)
    /// - streams: 2 (1 output + 1 input)
    /// - chmaps: 0 (no channel maps for v1)
    ///
    /// Called from the vCPU exit handler thread.
    public override func readDeviceConfig(offset: Int, size: Int) -> UInt32 {
        switch offset {
        case SoundConfigOffset.jacks:
            return 0  // No jacks

        case SoundConfigOffset.streams:
            return Self.streamCount  // 2 streams

        case SoundConfigOffset.chmaps:
            return 0  // No channel maps

        default:
            return 0
        }
    }

    /// Device config is read-only for virtio-snd.
    public override func writeDeviceConfig(offset: Int, size: Int, value: UInt32) {
        // Ignored — virtio-snd config is read-only.
    }

    // MARK: - Device Lifecycle

    /// Called when the guest driver sets DRIVER_OK.
    ///
    /// At this point feature negotiation is complete and queues are configured.
    /// We configure the AudioRouter with default parameters so it is ready
    /// when the guest starts streaming.
    public override func deviceActivated() {
        // AudioRouter configuration happens when the guest sends PCM_PREPARE,
        // because we need the negotiated format/rate/channels first.
        // Nothing to do here beyond logging readiness.
    }

    /// Reset all device-specific state.
    ///
    /// Called when the guest writes 0 to the device status register. Stop
    /// any active audio streams and return to initial state.
    public override func deviceReset() {
        for stream in streams {
            if stream.state == .running {
                stopAudioStream(stream)
            }
            stream.state = .undefined
            stream.params = PCMStreamParams()
            stream.latencyBytes = 0
        }
    }

    // MARK: - Queue Notification Dispatch

    /// Process I/O on a notified virtqueue.
    ///
    /// Called on the vCPU exit handler thread when the guest writes to
    /// a notification doorbell.
    public override func handleQueueNotification(queueIndex: Int) {
        switch queueIndex {
        case VirtioSoundQueue.control:
            processControlQueue()
        case VirtioSoundQueue.event:
            // Event queue is host->guest; guest posting buffers here means
            // it is providing empty buffers for us to fill with events.
            // We do not generate events in v1, so just leave them queued.
            break
        case VirtioSoundQueue.tx:
            processTXQueue()
        case VirtioSoundQueue.rx:
            processRXQueue()
        default:
            break
        }
    }

    // MARK: - Control Queue Processing

    /// Process all pending control messages on the controlq.
    ///
    /// Each control message is a descriptor chain with:
    ///   - Device-readable descriptors: request header + request-specific payload
    ///   - Device-writable descriptors: response header + response-specific payload
    private func processControlQueue() {
        let controlQueue = queues[VirtioSoundQueue.control]

        while let chain = controlQueue.nextAvailableChain() {
            let readable = chain.readableDescriptors
            let writable = chain.writableDescriptors

            guard let firstReadable = readable.first else {
                // Malformed chain: no readable descriptors.
                completeControlRequest(queue: controlQueue, chain: chain,
                                       status: VirtioSndStatus.badMsg, extraData: nil)
                continue
            }

            // Read the request header (virtio_snd_hdr: le32 code).
            let requestCode = controlQueue.guestMemory.readUInt32(at: firstReadable.addr)

            let bytesWritten = handleControlRequest(
                code: requestCode,
                readable: readable,
                writable: writable,
                memory: controlQueue.guestMemory
            )

            controlQueue.addUsed(headIndex: chain.headIndex, length: bytesWritten)
            signalUsedBuffers(queueIndex: VirtioSoundQueue.control)
        }
    }

    /// Dispatch a control request by its code and write the response.
    ///
    /// - Returns: Total bytes written to device-writable descriptors.
    private func handleControlRequest(
        code: UInt32,
        readable: [VirtqDescriptor],
        writable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor
    ) -> UInt32 {
        switch code {
        case VirtioSndRequestCode.jackInfo:
            return handleJackInfo(readable: readable, writable: writable, memory: memory)

        case VirtioSndRequestCode.pcmInfo:
            return handlePCMInfo(readable: readable, writable: writable, memory: memory)

        case VirtioSndRequestCode.pcmSetParams:
            return handlePCMSetParams(readable: readable, memory: memory,
                                       writable: writable)

        case VirtioSndRequestCode.pcmPrepare:
            return handlePCMStateChange(readable: readable, writable: writable,
                                        memory: memory, action: .prepare)

        case VirtioSndRequestCode.pcmRelease:
            return handlePCMStateChange(readable: readable, writable: writable,
                                        memory: memory, action: .release)

        case VirtioSndRequestCode.pcmStart:
            return handlePCMStateChange(readable: readable, writable: writable,
                                        memory: memory, action: .start)

        case VirtioSndRequestCode.pcmStop:
            return handlePCMStateChange(readable: readable, writable: writable,
                                        memory: memory, action: .stop)

        case VirtioSndRequestCode.chmapInfo:
            return handleChmapInfo(readable: readable, writable: writable, memory: memory)

        default:
            // Unknown request code.
            return writeStatusResponse(VirtioSndStatus.notSupported,
                                       writable: writable, memory: memory)
        }
    }

    // MARK: - JACK_INFO Handler

    /// Handle VIRTIO_SND_R_JACK_INFO.
    ///
    /// We advertise 0 jacks, so any query returns OK with an empty info array.
    /// The guest sends a `virtio_snd_query_info` (hdr + start_id + count + size).
    /// We respond with just the status header.
    private func handleJackInfo(
        readable: [VirtqDescriptor],
        writable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor
    ) -> UInt32 {
        // With 0 jacks, any query is valid but returns empty results.
        // Just write OK status.
        return writeStatusResponse(VirtioSndStatus.ok, writable: writable, memory: memory)
    }

    // MARK: - CHMAP_INFO Handler

    /// Handle VIRTIO_SND_R_CHMAP_INFO.
    ///
    /// We advertise 0 channel maps, so return OK with empty results.
    private func handleChmapInfo(
        readable: [VirtqDescriptor],
        writable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor
    ) -> UInt32 {
        return writeStatusResponse(VirtioSndStatus.ok, writable: writable, memory: memory)
    }

    // MARK: - PCM_INFO Handler

    /// Handle VIRTIO_SND_R_PCM_INFO.
    ///
    /// The guest sends `virtio_snd_query_info`:
    /// ```
    /// struct virtio_snd_query_info {
    ///     struct virtio_snd_hdr hdr;   // code = VIRTIO_SND_R_PCM_INFO
    ///     le32 start_id;               // first stream ID to query
    ///     le32 count;                  // number of streams to query
    ///     le32 size;                   // sizeof(virtio_snd_pcm_info) per the guest
    /// };
    /// ```
    ///
    /// We respond with:
    /// - `virtio_snd_hdr` with status OK
    /// - Array of `virtio_snd_pcm_info` structs (32 bytes each)
    private func handlePCMInfo(
        readable: [VirtqDescriptor],
        writable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor
    ) -> UInt32 {
        // Parse the query_info request. We need at least 16 bytes:
        // hdr (4) + start_id (4) + count (4) + size (4)
        let requestData = gatherReadableData(descriptors: readable, memory: memory)
        guard requestData.count >= 16 else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        let startID = requestData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        }
        let count = requestData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
        }

        // Validate range.
        guard startID + count <= Self.streamCount else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        // Build the response: status header + array of pcm_info structs.
        let pcmInfoSize = 32  // sizeof(virtio_snd_pcm_info)
        var response = Data(count: 4 + Int(count) * pcmInfoSize)

        // Write status header.
        var statusLE = VirtioSndStatus.ok.littleEndian
        response.replaceSubrange(0..<4, with: Data(bytes: &statusLE, count: 4))

        // Write each pcm_info struct.
        for i in 0..<Int(count) {
            let streamID = Int(startID) + i
            guard streamID < streams.count else { break }
            let stream = streams[streamID]
            let offset = 4 + i * pcmInfoSize

            var info = Data(count: pcmInfoSize)

            // hdr.hda_fn_nid (le32) — set to 0 (no HDA function node).
            info.writeLE32(at: 0, value: 0)

            // features (le32) — 0, no per-stream features.
            info.writeLE32(at: 4, value: 0)

            // formats (le64) — bitmask of supported formats.
            info.writeLE64(at: 8, value: supportedFormatsBitmask)

            // rates (le64) — bitmask of supported rates.
            info.writeLE64(at: 16, value: supportedRatesBitmask)

            // direction (u8)
            info[24] = stream.direction.rawValue

            // channels_min (u8)
            info[25] = 1

            // channels_max (u8)
            info[26] = 2

            // padding[5] — already zeroed.

            response.replaceSubrange(offset..<(offset + pcmInfoSize), with: info)
        }

        return scatterWritableData(response, descriptors: writable, memory: memory)
    }

    // MARK: - PCM_SET_PARAMS Handler

    /// Handle VIRTIO_SND_R_PCM_SET_PARAMS.
    ///
    /// Request layout (`virtio_snd_pcm_set_params`, 24 bytes):
    /// ```
    /// hdr.code (le32)       — VIRTIO_SND_R_PCM_SET_PARAMS
    /// hdr.stream_id (le32)  — which stream
    /// buffer_bytes (le32)
    /// period_bytes (le32)
    /// features (le32)
    /// channels (u8)
    /// format (u8)
    /// rate (u8)
    /// padding (u8)
    /// ```
    private func handlePCMSetParams(
        readable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor,
        writable: [VirtqDescriptor]
    ) -> UInt32 {
        let requestData = gatherReadableData(descriptors: readable, memory: memory)
        guard requestData.count >= 24 else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        let streamID = requestData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        }
        let bufferBytes = requestData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
        }
        let periodBytes = requestData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
        }
        // features at offset 16 — currently unused (must be 0).
        let channels = requestData[20]
        let formatRaw = requestData[21]
        let rateRaw = requestData[22]

        // Validate stream ID.
        guard streamID < Self.streamCount else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        // Validate format and rate.
        guard let format = VirtioSndPCMFormat(rawValue: formatRaw),
              let rate = VirtioSndPCMRate(rawValue: rateRaw) else {
            return writeStatusResponse(VirtioSndStatus.notSupported,
                                       writable: writable, memory: memory)
        }

        // Verify the format and rate are in our supported set.
        guard (format.bitmask & supportedFormatsBitmask) != 0,
              (rate.bitmask & supportedRatesBitmask) != 0 else {
            return writeStatusResponse(VirtioSndStatus.notSupported,
                                       writable: writable, memory: memory)
        }

        // Validate channels (1 or 2).
        guard channels >= 1 && channels <= 2 else {
            return writeStatusResponse(VirtioSndStatus.notSupported,
                                       writable: writable, memory: memory)
        }

        // Validate buffer/period sizes.
        guard bufferBytes > 0, periodBytes > 0, periodBytes <= bufferBytes else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        // State check: SET_PARAMS is valid from undefined, setParams, or prepared.
        let stream = streams[Int(streamID)]
        guard stream.state == .undefined ||
              stream.state == .setParams ||
              stream.state == .prepared else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        // Store parameters.
        stream.params.bufferBytes = bufferBytes
        stream.params.periodBytes = periodBytes
        stream.params.channels = channels
        stream.params.format = format
        stream.params.rate = rate
        stream.state = .setParams

        return writeStatusResponse(VirtioSndStatus.ok,
                                   writable: writable, memory: memory)
    }

    // MARK: - PCM State Change Handlers (PREPARE / START / STOP / RELEASE)

    /// Actions that change PCM stream state.
    private enum PCMAction {
        case prepare
        case start
        case stop
        case release
    }

    /// Handle PCM state change requests (PREPARE, START, STOP, RELEASE).
    ///
    /// All use `virtio_snd_pcm_hdr` (8 bytes): hdr.code (le32) + stream_id (le32).
    private func handlePCMStateChange(
        readable: [VirtqDescriptor],
        writable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor,
        action: PCMAction
    ) -> UInt32 {
        let requestData = gatherReadableData(descriptors: readable, memory: memory)
        guard requestData.count >= 8 else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        let streamID = requestData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        }

        guard streamID < Self.streamCount else {
            return writeStatusResponse(VirtioSndStatus.badMsg,
                                       writable: writable, memory: memory)
        }

        let stream = streams[Int(streamID)]

        switch action {
        case .prepare:
            guard stream.state == .setParams else {
                return writeStatusResponse(VirtioSndStatus.badMsg,
                                           writable: writable, memory: memory)
            }
            let status = prepareAudioStream(stream)
            if status == VirtioSndStatus.ok {
                stream.state = .prepared
            }
            return writeStatusResponse(status, writable: writable, memory: memory)

        case .start:
            guard stream.state == .prepared else {
                return writeStatusResponse(VirtioSndStatus.badMsg,
                                           writable: writable, memory: memory)
            }
            let status = startAudioStream(stream)
            if status == VirtioSndStatus.ok {
                stream.state = .running
            }
            return writeStatusResponse(status, writable: writable, memory: memory)

        case .stop:
            guard stream.state == .running else {
                return writeStatusResponse(VirtioSndStatus.badMsg,
                                           writable: writable, memory: memory)
            }
            stopAudioStream(stream)
            stream.state = .prepared
            return writeStatusResponse(VirtioSndStatus.ok,
                                       writable: writable, memory: memory)

        case .release:
            guard stream.state == .prepared else {
                return writeStatusResponse(VirtioSndStatus.badMsg,
                                           writable: writable, memory: memory)
            }
            releaseAudioStream(stream)
            stream.state = .setParams
            return writeStatusResponse(VirtioSndStatus.ok,
                                       writable: writable, memory: memory)
        }
    }

    // MARK: - Audio Stream Lifecycle

    /// Configure the AudioRouter for the stream's negotiated parameters.
    ///
    /// Maps virtio PCM format/rate/channels to CoreAudio AudioUnit configuration.
    private func prepareAudioStream(_ stream: PCMStream) -> UInt32 {
        let params = stream.params
        let sampleRate = params.rate.hz
        let channels = UInt32(params.channels)
        let bitDepth = coreBitDepth(for: params.format)

        // Configure the AudioRouter with the guest's negotiated format.
        audioRouter.sampleRate = sampleRate
        audioRouter.channelCount = channels
        audioRouter.bitDepth = bitDepth

        do {
            try audioRouter.configure(
                output: stream.direction == .output ? audioConfig.output : nil,
                input: stream.direction == .input ? audioConfig.input : nil
            )
        } catch {
            return VirtioSndStatus.ioError
        }

        return VirtioSndStatus.ok
    }

    /// Start the AudioRouter for this stream.
    private func startAudioStream(_ stream: PCMStream) -> UInt32 {
        do {
            try audioRouter.start()
        } catch {
            return VirtioSndStatus.ioError
        }
        return VirtioSndStatus.ok
    }

    /// Stop the AudioRouter for this stream.
    private func stopAudioStream(_ stream: PCMStream) {
        audioRouter.stop()
    }

    /// Release resources for this stream.
    private func releaseAudioStream(_ stream: PCMStream) {
        // The AudioRouter retains its units until reconfigured.
        // Reset the ring buffer to discard any stale data.
        if stream.direction == .output {
            audioRouter.outputRingBuffer?.reset()
        } else {
            audioRouter.inputRingBuffer?.reset()
        }
        stream.latencyBytes = 0
    }

    // MARK: - TX Queue Processing (Playback: Guest -> Host)

    /// Process all pending buffers on the TX (playback) queue.
    ///
    /// Each descriptor chain from the guest contains:
    ///   - Device-readable: `virtio_snd_pcm_xfer` header (4 bytes: le32 stream_id)
    ///                      followed by PCM audio data
    ///   - Device-writable: `virtio_snd_pcm_status` (8 bytes: le32 status + le32 latency_bytes)
    ///
    /// We extract the PCM data, write it into the AudioRingBuffer (which the
    /// CoreAudio output unit's render callback reads from), and post the status.
    private func processTXQueue() {
        let txQueue = queues[VirtioSoundQueue.tx]

        while let chain = txQueue.nextAvailableChain() {
            let readable = chain.readableDescriptors

            // Read the xfer header (first 4 bytes of readable data).
            guard let firstDesc = readable.first, firstDesc.len >= 4 else {
                completePCMXfer(queue: txQueue, chain: chain,
                                status: VirtioSndStatus.badMsg, latencyBytes: 0)
                continue
            }

            let streamID = txQueue.guestMemory.readUInt32(at: firstDesc.addr)

            // Validate stream.
            guard streamID < Self.streamCount else {
                completePCMXfer(queue: txQueue, chain: chain,
                                status: VirtioSndStatus.badMsg, latencyBytes: 0)
                continue
            }

            let stream = streams[Int(streamID)]

            guard stream.state == .running, stream.direction == .output else {
                completePCMXfer(queue: txQueue, chain: chain,
                                status: VirtioSndStatus.ioError, latencyBytes: 0)
                continue
            }

            // Gather PCM data from all readable descriptors, skipping the 4-byte header.
            let pcmData = gatherPCMData(descriptors: readable, memory: txQueue.guestMemory,
                                        headerSize: 4)

            // Write PCM data into the output ring buffer.
            if let ringBuffer = audioRouter.outputRingBuffer, pcmData.count > 0 {
                let bytesPerSample = MemoryLayout<Float>.size
                let format = stream.params.format

                if format == .float32 {
                    // Float32 data can go directly into the ring buffer.
                    pcmData.withUnsafeBytes { rawBuf in
                        let floatBuf = rawBuf.bindMemory(to: Float.self)
                        let ubp = UnsafeBufferPointer(start: floatBuf.baseAddress,
                                                      count: floatBuf.count)
                        let channels = Int(stream.params.channels)
                        let frameCount = floatBuf.count / max(channels, 1)
                        ringBuffer.write(ubp, frameCount: frameCount)
                    }
                } else {
                    // Convert integer PCM formats to Float32 for the ring buffer.
                    let floatSamples = convertToFloat32(data: pcmData, format: format,
                                                        channels: stream.params.channels)
                    floatSamples.withUnsafeBufferPointer { buf in
                        let channels = Int(stream.params.channels)
                        let frameCount = buf.count / max(channels, 1)
                        ringBuffer.write(buf, frameCount: frameCount)
                    }
                }

                // Update latency tracking.
                stream.latencyBytes = UInt32(ringBuffer.availableForRead)
                    * UInt32(bytesPerSample)
            }

            completePCMXfer(queue: txQueue, chain: chain,
                            status: VirtioSndStatus.ok,
                            latencyBytes: stream.latencyBytes)
        }
    }

    // MARK: - RX Queue Processing (Capture: Host -> Guest)

    /// Process all pending buffers on the RX (capture) queue.
    ///
    /// Each descriptor chain from the guest contains:
    ///   - Device-readable: `virtio_snd_pcm_xfer` header (4 bytes: le32 stream_id)
    ///   - Device-writable: PCM audio data buffer + `virtio_snd_pcm_status` at the end
    ///
    /// We read captured audio from the AudioRingBuffer (filled by the CoreAudio
    /// input unit's capture callback), write it into the guest's buffer, and
    /// post the status.
    private func processRXQueue() {
        let rxQueue = queues[VirtioSoundQueue.rx]

        while let chain = rxQueue.nextAvailableChain() {
            let readable = chain.readableDescriptors
            let writable = chain.writableDescriptors

            // Read the xfer header.
            guard let firstDesc = readable.first, firstDesc.len >= 4 else {
                completePCMXfer(queue: rxQueue, chain: chain,
                                status: VirtioSndStatus.badMsg, latencyBytes: 0)
                continue
            }

            let streamID = rxQueue.guestMemory.readUInt32(at: firstDesc.addr)

            guard streamID < Self.streamCount else {
                completePCMXfer(queue: rxQueue, chain: chain,
                                status: VirtioSndStatus.badMsg, latencyBytes: 0)
                continue
            }

            let stream = streams[Int(streamID)]

            guard stream.state == .running, stream.direction == .input else {
                completePCMXfer(queue: rxQueue, chain: chain,
                                status: VirtioSndStatus.ioError, latencyBytes: 0)
                continue
            }

            // The writable descriptors contain the PCM data buffer followed by
            // the 8-byte status struct at the end. We need to figure out how
            // much space is available for PCM data vs the status.
            let totalWritableBytes = writable.reduce(0) { $0 + Int($1.len) }
            let statusSize = 8  // sizeof(virtio_snd_pcm_status)
            let pcmBufferSize = max(totalWritableBytes - statusSize, 0)

            var bytesWritten: UInt32 = 0

            if let ringBuffer = audioRouter.inputRingBuffer, pcmBufferSize > 0 {
                let format = stream.params.format
                let channels = Int(stream.params.channels)

                if format == .float32 {
                    // Read Float32 directly from ring buffer into guest memory.
                    let maxSamples = pcmBufferSize / MemoryLayout<Float>.size
                    let frameCount = maxSamples / max(channels, 1)

                    let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxSamples)
                    defer { tempBuffer.deallocate() }

                    let dest = UnsafeMutableBufferPointer(start: tempBuffer, count: maxSamples)
                    let framesRead = ringBuffer.read(dest, frameCount: frameCount)
                    let samplesRead = framesRead * channels
                    let dataBytes = samplesRead * MemoryLayout<Float>.size

                    let pcmData = Data(bytes: tempBuffer, count: dataBytes)
                    bytesWritten = scatterPCMData(pcmData, descriptors: writable,
                                                  memory: rxQueue.guestMemory,
                                                  reserveTrailing: statusSize)
                } else {
                    // Read Float32 from ring buffer, then convert to the guest's format.
                    let bytesPerSample = format.bytesPerSample
                    guard bytesPerSample > 0 else {
                        completePCMXfer(queue: rxQueue, chain: chain,
                                        status: VirtioSndStatus.ioError, latencyBytes: 0)
                        continue
                    }
                    let maxFrames = pcmBufferSize / (bytesPerSample * channels)
                    let maxSamples = maxFrames * channels

                    let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxSamples)
                    defer { tempBuffer.deallocate() }

                    let dest = UnsafeMutableBufferPointer(start: tempBuffer, count: maxSamples)
                    let framesRead = ringBuffer.read(dest, frameCount: maxFrames)

                    if framesRead > 0 {
                        let floatBuf = UnsafeBufferPointer(start: tempBuffer,
                                                           count: framesRead * channels)
                        let intData = convertFromFloat32(samples: floatBuf, format: format)
                        bytesWritten = scatterPCMData(intData, descriptors: writable,
                                                      memory: rxQueue.guestMemory,
                                                      reserveTrailing: statusSize)
                    }
                }

                stream.latencyBytes = UInt32(ringBuffer.availableForRead)
                    * UInt32(MemoryLayout<Float>.size)
            }

            // Write the status at the end of the writable region.
            let statusOffset = totalWritableBytes - statusSize
            writeStatusAtOffset(writable: writable, memory: rxQueue.guestMemory,
                                byteOffset: statusOffset,
                                status: VirtioSndStatus.ok,
                                latencyBytes: stream.latencyBytes)

            let totalBytesWritten = bytesWritten + UInt32(statusSize)
            rxQueue.addUsed(headIndex: chain.headIndex, length: totalBytesWritten)
            signalUsedBuffers(queueIndex: VirtioSoundQueue.rx)
        }
    }

    // MARK: - Completion Helpers

    /// Complete a PCM xfer by writing the status struct to the writable descriptor
    /// and posting the chain to the used ring.
    private func completePCMXfer(
        queue: VirtQueue,
        chain: DescriptorChain,
        status: UInt32,
        latencyBytes: UInt32
    ) {
        let writable = chain.writableDescriptors

        // Write virtio_snd_pcm_status: le32 status + le32 latency_bytes.
        // For TX: the status is the only writable content.
        // For RX: the status is at the end (after PCM data). For error cases
        // where we write no PCM data, write status at the start.
        if let firstWritable = writable.last {
            // Write status at the end of the last writable descriptor.
            let statusOffset = firstWritable.addr + UInt64(firstWritable.len) - 8
            queue.guestMemory.writeUInt32(at: statusOffset, value: status)
            queue.guestMemory.writeUInt32(at: statusOffset + 4, value: latencyBytes)
        }

        // For TX, the total bytes written is just the 8-byte status.
        // For RX error cases, also 8 bytes (no PCM data written).
        queue.addUsed(headIndex: chain.headIndex, length: 8)
        let queueIndex = (queue === queues[VirtioSoundQueue.tx])
            ? VirtioSoundQueue.tx : VirtioSoundQueue.rx
        signalUsedBuffers(queueIndex: queueIndex)
    }

    /// Write a simple status-only response to the control queue.
    private func completeControlRequest(
        queue: VirtQueue,
        chain: DescriptorChain,
        status: UInt32,
        extraData: Data?
    ) {
        let writable = chain.writableDescriptors
        var response = Data(count: 4)
        var statusLE = status.littleEndian
        response.replaceSubrange(0..<4, with: Data(bytes: &statusLE, count: 4))
        if let extra = extraData {
            response.append(extra)
        }
        let written = scatterWritableData(response, descriptors: writable,
                                          memory: queue.guestMemory)
        queue.addUsed(headIndex: chain.headIndex, length: written)
        signalUsedBuffers(queueIndex: VirtioSoundQueue.control)
    }

    /// Write a status response (virtio_snd_hdr with status code) to writable descriptors.
    ///
    /// - Returns: Bytes written.
    private func writeStatusResponse(
        _ status: UInt32,
        writable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor
    ) -> UInt32 {
        var response = Data(count: 4)
        var statusLE = status.littleEndian
        response.replaceSubrange(0..<4, with: Data(bytes: &statusLE, count: 4))
        return scatterWritableData(response, descriptors: writable, memory: memory)
    }

    /// Write a PCM status struct at a specific byte offset within the writable descriptors.
    private func writeStatusAtOffset(
        writable: [VirtqDescriptor],
        memory: any GuestMemoryAccessor,
        byteOffset: Int,
        status: UInt32,
        latencyBytes: UInt32
    ) {
        // Walk descriptors to find the one containing the target offset.
        var remaining = byteOffset
        for desc in writable {
            let descLen = Int(desc.len)
            if remaining < descLen {
                let addr = desc.addr + UInt64(remaining)
                memory.writeUInt32(at: addr, value: status)
                if remaining + 4 < descLen {
                    memory.writeUInt32(at: addr + 4, value: latencyBytes)
                }
                // If the status struct spans two descriptors (unlikely but possible),
                // we handle the simple case where it fits in one.
                return
            }
            remaining -= descLen
        }
    }

    // MARK: - Data Gathering / Scattering

    /// Read all device-readable data from a descriptor chain into a contiguous buffer.
    private func gatherReadableData(
        descriptors: [VirtqDescriptor],
        memory: any GuestMemoryAccessor
    ) -> Data {
        var result = Data()
        for desc in descriptors where desc.isDeviceReadable {
            let data = memory.read(at: desc.addr, size: Int(desc.len))
            result.append(data)
        }
        return result
    }

    /// Gather PCM audio data from readable descriptors, skipping headerSize bytes
    /// from the beginning of the first descriptor.
    private func gatherPCMData(
        descriptors: [VirtqDescriptor],
        memory: any GuestMemoryAccessor,
        headerSize: Int
    ) -> Data {
        var result = Data()
        var bytesToSkip = headerSize

        for desc in descriptors where desc.isDeviceReadable {
            let descLen = Int(desc.len)
            if bytesToSkip >= descLen {
                bytesToSkip -= descLen
                continue
            }
            let readOffset = UInt64(bytesToSkip)
            let readLen = descLen - bytesToSkip
            let data = memory.read(at: desc.addr + readOffset, size: readLen)
            result.append(data)
            bytesToSkip = 0
        }
        return result
    }

    /// Scatter response data across device-writable descriptors.
    ///
    /// - Returns: Total bytes written.
    @discardableResult
    private func scatterWritableData(
        _ data: Data,
        descriptors: [VirtqDescriptor],
        memory: any GuestMemoryAccessor
    ) -> UInt32 {
        var offset = 0
        for desc in descriptors where desc.isDeviceWritable {
            guard offset < data.count else { break }
            let writeLen = min(Int(desc.len), data.count - offset)
            let chunk = data.dropFirst(offset).prefix(writeLen)
            memory.write(at: desc.addr, data: Data(chunk))
            offset += writeLen
        }
        return UInt32(offset)
    }

    /// Scatter PCM data into writable descriptors, reserving trailing bytes
    /// for the status struct.
    ///
    /// - Returns: Bytes of PCM data written (excluding the reserved trailing bytes).
    private func scatterPCMData(
        _ data: Data,
        descriptors: [VirtqDescriptor],
        memory: any GuestMemoryAccessor,
        reserveTrailing: Int
    ) -> UInt32 {
        let totalWritable = descriptors.reduce(0) { $0 + Int($1.len) }
        let maxPCMBytes = max(totalWritable - reserveTrailing, 0)
        let pcmBytes = min(data.count, maxPCMBytes)

        var offset = 0
        for desc in descriptors where desc.isDeviceWritable {
            guard offset < pcmBytes else { break }
            let writeLen = min(Int(desc.len), pcmBytes - offset)
            let chunk = data.dropFirst(offset).prefix(writeLen)
            memory.write(at: desc.addr, data: Data(chunk))
            offset += writeLen
        }
        return UInt32(offset)
    }

    // MARK: - Format Conversion (Guest PCM <-> Float32)

    /// Convert guest PCM data (S16LE, S32LE) to Float32 for the ring buffer.
    ///
    /// This runs on the vCPU thread (not the audio callback), so allocation
    /// is acceptable here.
    private func convertToFloat32(
        data: Data,
        format: VirtioSndPCMFormat,
        channels: UInt8
    ) -> [Float] {
        switch format {
        case .s16:
            // S16LE -> Float32: divide by 32768.0
            let sampleCount = data.count / 2
            var result = [Float](repeating: 0, count: sampleCount)
            data.withUnsafeBytes { rawBuf in
                let s16Buf = rawBuf.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    result[i] = Float(Int16(littleEndian: s16Buf[i])) / 32768.0
                }
            }
            return result

        case .s32:
            // S32LE -> Float32: divide by 2^31.
            let sampleCount = data.count / 4
            var result = [Float](repeating: 0, count: sampleCount)
            data.withUnsafeBytes { rawBuf in
                let s32Buf = rawBuf.bindMemory(to: Int32.self)
                for i in 0..<sampleCount {
                    result[i] = Float(Int32(littleEndian: s32Buf[i])) / 2147483648.0
                }
            }
            return result

        case .float32:
            // Already Float32 — should not reach here, but handle gracefully.
            let sampleCount = data.count / 4
            var result = [Float](repeating: 0, count: sampleCount)
            data.withUnsafeBytes { rawBuf in
                let floatBuf = rawBuf.bindMemory(to: Float.self)
                for i in 0..<sampleCount {
                    result[i] = floatBuf[i]
                }
            }
            return result

        default:
            // Unsupported format — return silence.
            return []
        }
    }

    /// Convert Float32 samples from the ring buffer to the guest's PCM format.
    ///
    /// This runs on the vCPU thread (not the audio callback).
    private func convertFromFloat32(
        samples: UnsafeBufferPointer<Float>,
        format: VirtioSndPCMFormat
    ) -> Data {
        switch format {
        case .s16:
            // Float32 -> S16LE: multiply by 32767 and clamp.
            var result = Data(count: samples.count * 2)
            result.withUnsafeMutableBytes { rawBuf in
                let s16Buf = rawBuf.bindMemory(to: Int16.self)
                for i in 0..<samples.count {
                    let clamped = max(-1.0, min(1.0, samples[i]))
                    s16Buf[i] = Int16(clamped * 32767.0).littleEndian
                }
            }
            return result

        case .s32:
            // Float32 -> S32LE: multiply by 2^31-1 and clamp.
            var result = Data(count: samples.count * 4)
            result.withUnsafeMutableBytes { rawBuf in
                let s32Buf = rawBuf.bindMemory(to: Int32.self)
                for i in 0..<samples.count {
                    let clamped = max(-1.0, min(1.0, samples[i]))
                    s32Buf[i] = Int32(clamped * 2147483647.0).littleEndian
                }
            }
            return result

        case .float32:
            return Data(bytes: samples.baseAddress!, count: samples.count * 4)

        default:
            return Data()
        }
    }

    /// Map virtio PCM format to CoreAudio bit depth.
    ///
    /// The AudioRouter uses bitDepth to select between Int16 (16) and Float32 (32).
    private func coreBitDepth(for format: VirtioSndPCMFormat) -> UInt32 {
        switch format {
        case .s16, .u16:     return 16
        case .s32, .u32:     return 32
        case .float32:       return 32
        default:             return 32  // Default to Float32 for unsupported formats
        }
    }
}

// MARK: - Data Helpers

private extension Data {
    /// Write a little-endian UInt32 at the given byte offset.
    mutating func writeLE32(at offset: Int, value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { src in
            for i in 0..<4 {
                self[offset + i] = src[i]
            }
        }
    }

    /// Write a little-endian UInt64 at the given byte offset.
    mutating func writeLE64(at offset: Int, value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { src in
            for i in 0..<8 {
                self[offset + i] = src[i]
            }
        }
    }
}
