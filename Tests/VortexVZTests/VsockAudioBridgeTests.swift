// VsockAudioBridgeTests.swift — Tests for VsockAudioBridge device hot-swap.
// VortexVZTests

import Testing
import Foundation
@testable import VortexVZ
@testable import VortexAudio

@Suite("VsockAudioBridge")
struct VsockAudioBridgeTests {

    @Test("Bridge initializes with deviceDisconnected = false")
    func bridgeInitialState() {
        let bridge = VsockAudioBridge(vmID: UUID())

        #expect(!bridge.deviceDisconnected,
            "Bridge should start with deviceDisconnected=false")
        #expect(!bridge.isAttached)
        #expect(!bridge.isStreaming)
        #expect(bridge.negotiatedFormat == nil)
    }

    @Test("Bridge detach resets deviceDisconnected flag")
    func bridgeDetachResetsFlag() {
        let bridge = VsockAudioBridge(vmID: UUID())
        // Detach on an already-detached bridge should be safe.
        bridge.detach()

        #expect(!bridge.deviceDisconnected)
        #expect(!bridge.isAttached)
    }

    @Test("VsockAudioFormat serialization round-trips")
    func formatRoundTrip() {
        let original = VsockAudioFormat(
            sampleRate: 44100,
            channels: 1,
            bitsPerSample: 16,
            isFloat: false
        )

        let data = original.serialize()
        #expect(data.count == VsockAudioFormat.wireSize)

        let deserialized = VsockAudioFormat.deserialize(from: data)
        #expect(deserialized != nil)
        #expect(deserialized == original)
    }

    @Test("VsockAudioFormat deserialization rejects short data")
    func formatRejectsShortData() {
        let shortData = Data([0x01, 0x02])
        let result = VsockAudioFormat.deserialize(from: shortData)
        #expect(result == nil, "Should return nil for data shorter than wireSize")
    }

    @Test("VsockAudioFormat bytesPerFrame calculation")
    func formatBytesPerFrame() {
        let stereoFloat32 = VsockAudioFormat(
            sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true
        )
        #expect(stereoFloat32.bytesPerFrame == 8) // 2 channels * 4 bytes

        let monoInt16 = VsockAudioFormat(
            sampleRate: 44100, channels: 1, bitsPerSample: 16, isFloat: false
        )
        #expect(monoInt16.bytesPerFrame == 2) // 1 channel * 2 bytes
    }

    @Test("VsockAudioMessageType raw values match wire protocol")
    func messageTypeRawValues() {
        #expect(VsockAudioMessageType.configure.rawValue == 0x01)
        #expect(VsockAudioMessageType.pcmOutput.rawValue == 0x02)
        #expect(VsockAudioMessageType.pcmInput.rawValue == 0x03)
        #expect(VsockAudioMessageType.start.rawValue == 0x04)
        #expect(VsockAudioMessageType.stop.rawValue == 0x05)
        #expect(VsockAudioMessageType.latencyQuery.rawValue == 0x06)
        #expect(VsockAudioMessageType.latencyReply.rawValue == 0x07)
    }

    @Test("onDeviceStateChanged callback type is settable")
    func deviceStateChangedCallbackSettable() {
        let bridge = VsockAudioBridge(vmID: UUID())
        var callbackFired = false

        bridge.onDeviceStateChanged = { disconnected, direction, uid in
            callbackFired = true
            _ = disconnected
            _ = direction
            _ = uid
        }

        // The callback is stored; we cannot trigger it without a real
        // device event, but we verify it compiles and is settable.
        #expect(!callbackFired,
            "Callback should not fire until a device event occurs")
    }
}
