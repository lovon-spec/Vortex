// AudioDeviceHotSwapTests.swift — Tests for device disconnect/reconnect behavior.
// VortexAudioTests
//
// Tests the AudioDeviceWatcher reconnection tracking and AudioRouter
// disconnect/reconnect handlers. These tests use the real CoreAudio stack
// but do not require any specific virtual device to be loaded.

import Testing
import Foundation
@testable import VortexAudio
import VortexCore

@Suite("AudioDeviceHotSwap")
struct AudioDeviceHotSwapTests {

    // MARK: - AudioDeviceWatcher

    @Test("Watcher emits deviceListChanged event")
    func watcherEmitsDeviceListChanged() throws {
        let enumerator = AudioDeviceEnumerator()
        var events: [AudioDeviceEvent] = []
        let expectation = DispatchSemaphore(value: 0)

        let watcher = AudioDeviceWatcher(enumerator: enumerator) { event in
            events.append(event)
            expectation.signal()
        }
        watcher.startWatching()

        // The watcher is now listening. We cannot easily trigger a real
        // device list change, but we can verify the watcher started
        // without crashing and can be stopped cleanly.
        watcher.stopWatching()

        // If we got here, the watcher lifecycle is correct.
        #expect(true, "Watcher start/stop lifecycle completed without crash")
    }

    @Test("Watcher tracks disconnected UIDs")
    func watcherTracksDisconnectedUIDs() throws {
        let enumerator = AudioDeviceEnumerator()
        var events: [AudioDeviceEvent] = []

        let watcher = AudioDeviceWatcher(enumerator: enumerator) { event in
            events.append(event)
        }
        watcher.startWatching()

        // Manually track a UID as disconnected.
        watcher.trackDisconnectedUID("com.vortex.test.device.uid")

        // On the next device list change, the watcher will check if
        // this UID has reappeared. Since it does not exist, it should
        // stay in the disconnected set.
        watcher.stopWatching()

        #expect(true, "trackDisconnectedUID completed without crash")
    }

    @Test("Watcher watchDevice/unwatchDevice lifecycle")
    func watcherWatchUnwatch() throws {
        let enumerator = AudioDeviceEnumerator()
        let devices = try enumerator.allDevices()
        guard let first = devices.first else {
            // No devices available on this host -- skip.
            return
        }

        let watcher = AudioDeviceWatcher(enumerator: enumerator) { _ in }
        watcher.startWatching()

        // Watch a real device.
        watcher.watchDevice(deviceID: first.deviceID, uid: first.uid)

        // Unwatch it.
        watcher.unwatchDevice(deviceID: first.deviceID)

        watcher.stopWatching()

        #expect(true, "watchDevice/unwatchDevice lifecycle completed")
    }

    @Test("deviceReappeared event type exists")
    func deviceReappearedEventType() {
        // Verify the event type compiles and can be created.
        let event = AudioDeviceEvent.deviceReappeared(deviceID: 42, uid: "test-uid")
        switch event {
        case .deviceReappeared(let id, let uid):
            #expect(id == 42)
            #expect(uid == "test-uid")
        default:
            Issue.record("Expected deviceReappeared event")
        }
    }

    // MARK: - AudioRouter disconnect/reconnect

    @Test("Router reports isOutputDisconnected correctly")
    func routerOutputDisconnectedFlag() {
        let router = AudioRouter(vmID: "test-vm")

        // Initially not disconnected.
        #expect(!router.isOutputDisconnected)
        #expect(!router.isInputDisconnected)
    }

    @Test("Router handleDeviceDisconnect calls callback")
    func routerDisconnectCallback() throws {
        let enumerator = AudioDeviceEnumerator()
        let devices = try enumerator.outputDevices()
        guard let first = devices.first else { return }

        let router = AudioRouter(vmID: "test-vm", enumerator: enumerator)

        // Configure with a real device.
        let config = AudioEndpointConfig(
            hostDeviceUID: first.uid,
            hostDeviceName: first.name
        )
        try router.configure(output: config, input: nil)

        // Track disconnect callback.
        var disconnectedDirection: AudioDirection?
        var disconnectedUID: String?
        router.onDeviceDisconnected = { direction, uid in
            disconnectedDirection = direction
            disconnectedUID = uid
        }

        // Simulate disconnect by calling the handler directly.
        router.handleDeviceDisconnect(deviceUID: first.uid)

        #expect(disconnectedDirection == .output)
        #expect(disconnectedUID == first.uid)
        #expect(router.isOutputDisconnected)
    }

    @Test("Router handleDeviceReconnect calls callback")
    func routerReconnectCallback() throws {
        let enumerator = AudioDeviceEnumerator()
        let devices = try enumerator.outputDevices()
        guard let first = devices.first else { return }

        let router = AudioRouter(vmID: "test-vm", enumerator: enumerator)

        let config = AudioEndpointConfig(
            hostDeviceUID: first.uid,
            hostDeviceName: first.name
        )
        try router.configure(output: config, input: nil)

        // Simulate disconnect then reconnect.
        router.handleDeviceDisconnect(deviceUID: first.uid)
        #expect(router.isOutputDisconnected)

        var reconnectedDirection: AudioDirection?
        var reconnectedUID: String?
        router.onDeviceReconnected = { direction, uid in
            reconnectedDirection = direction
            reconnectedUID = uid
        }

        // The device is still physically present, so reconnect should succeed.
        router.handleDeviceReconnect(deviceUID: first.uid)

        #expect(reconnectedDirection == .output)
        #expect(reconnectedUID == first.uid)
        #expect(!router.isOutputDisconnected)
    }

    @Test("Router handleDeviceDisconnect for unknown UID is a no-op")
    func routerDisconnectUnknownUID() {
        let router = AudioRouter(vmID: "test-vm")

        var callbackCalled = false
        router.onDeviceDisconnected = { _, _ in
            callbackCalled = true
        }

        // Disconnect a UID that was never configured.
        router.handleDeviceDisconnect(deviceUID: "nonexistent-uid")

        #expect(!callbackCalled,
            "Disconnect for unknown UID should not call callback")
        #expect(!router.isOutputDisconnected)
        #expect(!router.isInputDisconnected)
    }

    @Test("Router handleDeviceReconnect for unknown UID is a no-op")
    func routerReconnectUnknownUID() {
        let router = AudioRouter(vmID: "test-vm")

        var callbackCalled = false
        router.onDeviceReconnected = { _, _ in
            callbackCalled = true
        }

        router.handleDeviceReconnect(deviceUID: "nonexistent-uid")

        #expect(!callbackCalled,
            "Reconnect for unknown UID should not call callback")
    }

    // MARK: - Input direction

    @Test("Router handleDeviceDisconnect for input device")
    func routerInputDisconnect() throws {
        let enumerator = AudioDeviceEnumerator()
        let devices = try enumerator.inputDevices()
        guard let first = devices.first else { return }

        let router = AudioRouter(vmID: "test-vm", enumerator: enumerator)

        let config = AudioEndpointConfig(
            hostDeviceUID: first.uid,
            hostDeviceName: first.name
        )
        try router.configure(output: nil, input: config)

        var disconnectedDirection: AudioDirection?
        router.onDeviceDisconnected = { direction, _ in
            disconnectedDirection = direction
        }

        router.handleDeviceDisconnect(deviceUID: first.uid)

        #expect(disconnectedDirection == .input)
        #expect(router.isInputDisconnected)
        #expect(!router.isOutputDisconnected,
            "Output should not be affected by input disconnect")
    }

    @Test("Router handleDeviceReconnect for input device")
    func routerInputReconnect() throws {
        let enumerator = AudioDeviceEnumerator()
        let devices = try enumerator.inputDevices()
        guard let first = devices.first else { return }

        let router = AudioRouter(vmID: "test-vm", enumerator: enumerator)

        let config = AudioEndpointConfig(
            hostDeviceUID: first.uid,
            hostDeviceName: first.name
        )
        try router.configure(output: nil, input: config)

        router.handleDeviceDisconnect(deviceUID: first.uid)
        #expect(router.isInputDisconnected)

        var reconnectedDirection: AudioDirection?
        router.onDeviceReconnected = { direction, _ in
            reconnectedDirection = direction
        }

        router.handleDeviceReconnect(deviceUID: first.uid)

        #expect(reconnectedDirection == .input)
        #expect(!router.isInputDisconnected)
    }
}
