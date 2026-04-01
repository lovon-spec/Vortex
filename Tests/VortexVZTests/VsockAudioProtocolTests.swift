// VsockAudioProtocolTests.swift — Tests for the vsock audio wire protocol.
// VortexVZTests

import Foundation
import Testing

@testable import VortexVZ

// MARK: - VsockAudioFormat Wire Protocol Tests

@Suite("VsockAudioFormat serialization")
struct VsockAudioFormatTests {

    @Test("Round-trip serialization of default Float32 format")
    func roundTripFloat32() {
        let original = VsockAudioFormat(
            sampleRate: 48000,
            channels: 2,
            bitsPerSample: 32,
            isFloat: true
        )

        let data = original.serialize()
        #expect(data.count == VsockAudioFormat.wireSize)

        let decoded = VsockAudioFormat.deserialize(from: data)
        #expect(decoded != nil)
        #expect(decoded == original)
    }

    @Test("Round-trip serialization of Int16 format")
    func roundTripInt16() {
        let original = VsockAudioFormat(
            sampleRate: 44100,
            channels: 1,
            bitsPerSample: 16,
            isFloat: false
        )

        let data = original.serialize()
        let decoded = VsockAudioFormat.deserialize(from: data)
        #expect(decoded != nil)
        #expect(decoded == original)
    }

    @Test("Deserialization from truncated data returns nil")
    func truncatedData() {
        let data = Data([0x01, 0x02, 0x03]) // Too short.
        let decoded = VsockAudioFormat.deserialize(from: data)
        #expect(decoded == nil)
    }

    @Test("Wire size is 13 bytes")
    func wireSize() {
        #expect(VsockAudioFormat.wireSize == 13)
    }

    @Test("Bytes per frame calculation")
    func bytesPerFrame() {
        let stereoFloat = VsockAudioFormat(
            sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true
        )
        #expect(stereoFloat.bytesPerFrame == 8)

        let stereoInt16 = VsockAudioFormat(
            sampleRate: 44100, channels: 2, bitsPerSample: 16, isFloat: false
        )
        #expect(stereoInt16.bytesPerFrame == 4)

        let monoFloat = VsockAudioFormat(
            sampleRate: 48000, channels: 1, bitsPerSample: 32, isFloat: true
        )
        #expect(monoFloat.bytesPerFrame == 4)
    }

    @Test("Format with exotic sample rate round-trips")
    func exoticSampleRate() {
        let original = VsockAudioFormat(
            sampleRate: 96000,
            channels: 8,
            bitsPerSample: 32,
            isFloat: true
        )

        let data = original.serialize()
        let decoded = VsockAudioFormat.deserialize(from: data)
        #expect(decoded == original)
    }

    @Test("Serialization uses little-endian byte order")
    func littleEndian() {
        let format = VsockAudioFormat(
            sampleRate: 48000,  // 0x0000BB80
            channels: 2,       // 0x00000002
            bitsPerSample: 32, // 0x00000020
            isFloat: true
        )

        let data = format.serialize()
        // Sample rate bytes (little-endian): 0x80, 0xBB, 0x00, 0x00
        #expect(data[0] == 0x80)
        #expect(data[1] == 0xBB)
        #expect(data[2] == 0x00)
        #expect(data[3] == 0x00)

        // Channels: 0x02, 0x00, 0x00, 0x00
        #expect(data[4] == 0x02)
        #expect(data[5] == 0x00)

        // Bits per sample: 0x20, 0x00, 0x00, 0x00
        #expect(data[8] == 0x20)
        #expect(data[9] == 0x00)

        // isFloat: 0x01
        #expect(data[12] == 0x01)
    }
}

// MARK: - VsockAudioFormat Version Extension Tests

@Suite("VsockAudioFormat version handling")
struct VsockAudioFormatVersionTests {

    @Test("wireSizeV1 is 17 bytes")
    func wireSizeV1() {
        #expect(VsockAudioFormat.wireSizeV1 == 17)
        #expect(VsockAudioFormat.wireSizeV1 == VsockAudioFormat.wireSize + 4)
    }

    @Test("serializeWithVersion produces 17-byte payload")
    func serializeWithVersionSize() {
        let format = VsockAudioFormat()
        let data = format.serializeWithVersion(1)
        #expect(data.count == VsockAudioFormat.wireSizeV1)
    }

    @Test("Round-trip format with version preserves both format and version")
    func roundTripWithVersion() {
        let original = VsockAudioFormat(
            sampleRate: 44100,
            channels: 1,
            bitsPerSample: 16,
            isFloat: false
        )
        let version: UInt32 = 42

        let data = original.serializeWithVersion(version)

        let decoded = VsockAudioFormat.deserialize(from: data)
        #expect(decoded == original)

        let extractedVersion = VsockAudioFormat.extractProtocolVersion(from: data)
        #expect(extractedVersion == version)
    }

    @Test("extractProtocolVersion returns nil for 13-byte (v0) payload")
    func noVersionInLegacyPayload() {
        let format = VsockAudioFormat()
        let data = format.serialize()
        #expect(data.count == 13)

        let version = VsockAudioFormat.extractProtocolVersion(from: data)
        #expect(version == nil)
    }

    @Test("extractProtocolVersion returns correct value for v1 payload")
    func versionFromV1Payload() {
        let format = VsockAudioFormat()
        let data = format.serializeWithVersion(1)

        let version = VsockAudioFormat.extractProtocolVersion(from: data)
        #expect(version == 1)
    }

    @Test("Deserialization of v1 payload still returns correct audio format")
    func v1PayloadFormatsMatch() {
        let format = VsockAudioFormat(
            sampleRate: 96000,
            channels: 8,
            bitsPerSample: 32,
            isFloat: true
        )

        let v0Data = format.serialize()
        let v1Data = format.serializeWithVersion(1)

        let v0Format = VsockAudioFormat.deserialize(from: v0Data)
        let v1Format = VsockAudioFormat.deserialize(from: v1Data)
        #expect(v0Format == v1Format)
        #expect(v0Format == format)
    }

    @Test("Version field uses little-endian byte order")
    func versionLittleEndian() {
        let format = VsockAudioFormat()
        let data = format.serializeWithVersion(0x0100_0002)  // 16777218

        // Bytes 13-16 should be LE: 0x02, 0x00, 0x00, 0x01
        #expect(data[13] == 0x02)
        #expect(data[14] == 0x00)
        #expect(data[15] == 0x00)
        #expect(data[16] == 0x01)
    }

    @Test("extractProtocolVersion from truncated data returns nil")
    func truncatedVersionData() {
        // 15 bytes: has format but version is incomplete
        let format = VsockAudioFormat()
        var data = format.serialize()
        data.append(contentsOf: [0x01, 0x00])  // Only 2 of 4 version bytes
        #expect(data.count == 15)

        let version = VsockAudioFormat.extractProtocolVersion(from: data)
        #expect(version == nil)
    }
}

// MARK: - VsockAudioBridge Protocol Version Tests

@Suite("VsockAudioBridge protocol version constant")
struct VsockAudioBridgeVersionTests {

    @Test("Protocol version is 1")
    func protocolVersion() {
        #expect(VsockAudioBridge.protocolVersion == 1)
    }
}

// MARK: - VsockAudioMessageType Tests

@Suite("VsockAudioMessageType values")
struct VsockAudioMessageTypeTests {

    @Test("Message type raw values match wire protocol spec")
    func rawValues() {
        #expect(VsockAudioMessageType.configure.rawValue == 0x01)
        #expect(VsockAudioMessageType.pcmOutput.rawValue == 0x02)
        #expect(VsockAudioMessageType.pcmInput.rawValue == 0x03)
        #expect(VsockAudioMessageType.start.rawValue == 0x04)
        #expect(VsockAudioMessageType.stop.rawValue == 0x05)
        #expect(VsockAudioMessageType.latencyQuery.rawValue == 0x06)
        #expect(VsockAudioMessageType.latencyReply.rawValue == 0x07)
        #expect(VsockAudioMessageType.versionMismatch.rawValue == 0x08)
    }

    @Test("Unknown raw value returns nil")
    func unknownValue() {
        #expect(VsockAudioMessageType(rawValue: 0xFF) == nil)
        #expect(VsockAudioMessageType(rawValue: 0x00) == nil)
    }
}
