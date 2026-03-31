// AudioDeviceEnumeratorTests.swift — Test device enumeration on real hardware.
// VortexAudioTests

import Testing
@testable import VortexAudio

@Suite("AudioDeviceEnumerator")
struct AudioDeviceEnumeratorTests {

    private let enumerator = AudioDeviceEnumerator()

    @Test("All devices returns a non-empty list")
    func allDevicesReturnsNonEmptyList() throws {
        // Every Mac has at least one audio device (built-in output).
        let devices = try enumerator.allDevices()
        #expect(!devices.isEmpty,
            "Expected at least one audio device on this host")

        // Every device should have a non-empty name and UID.
        for device in devices {
            #expect(!device.uid.isEmpty,
                "Device \(device.deviceID) has empty UID")
            #expect(!device.name.isEmpty,
                "Device \(device.deviceID) has empty name")
        }
    }

    @Test("Output devices are a subset of all devices")
    func outputDevicesSubsetOfAll() throws {
        let all = try enumerator.allDevices()
        let outputs = try enumerator.outputDevices()

        for output in outputs {
            #expect(output.isOutput,
                "Output device \(output.name) should have isOutput=true")
            #expect(all.contains(output),
                "Output device \(output.name) should be in allDevices()")
        }
    }

    @Test("Input devices are a subset of all devices")
    func inputDevicesSubsetOfAll() throws {
        let all = try enumerator.allDevices()
        let inputs = try enumerator.inputDevices()

        for input in inputs {
            #expect(input.isInput,
                "Input device \(input.name) should have isInput=true")
            #expect(all.contains(input),
                "Input device \(input.name) should be in allDevices()")
        }
    }

    @Test("Lookup device by UID")
    func deviceByUID() throws {
        let devices = try enumerator.allDevices()
        guard let first = devices.first else { return }

        let found = try enumerator.device(uid: first.uid)
        #expect(found != nil, "Should find device by UID")
        #expect(found?.deviceID == first.deviceID)
        #expect(found?.name == first.name)
    }

    @Test("Resolve device ID from UID")
    func deviceIDForUID() throws {
        let devices = try enumerator.allDevices()
        guard let first = devices.first else { return }

        let resolvedID = try enumerator.deviceID(forUID: first.uid)
        #expect(resolvedID != nil, "Should resolve device ID from UID")
        #expect(resolvedID == first.deviceID)
    }

    @Test("Unknown UID returns nil for deviceID")
    func deviceIDForUnknownUIDReturnsNil() throws {
        let resolvedID = try enumerator.deviceID(
            forUID: "com.vortex.nonexistent.device.uid.12345"
        )
        #expect(resolvedID == nil,
            "Should return nil for non-existent device UID")
    }

    @Test("Unknown UID returns nil for device lookup")
    func deviceByUnknownUIDReturnsNil() throws {
        let found = try enumerator.device(
            uid: "com.vortex.nonexistent.device.uid.12345"
        )
        #expect(found == nil,
            "Should return nil for non-existent device UID")
    }

    @Test("Each device is at least input or output")
    func eachDeviceIsInputOrOutput() throws {
        let devices = try enumerator.allDevices()
        for device in devices {
            #expect(device.isInput || device.isOutput,
                "Device \(device.name) should be at least input or output")
        }
    }

    @Test("Device description contains name and UID")
    func deviceDescriptionContainsName() throws {
        let devices = try enumerator.allDevices()
        guard let first = devices.first else { return }

        let desc = String(describing: first)
        #expect(desc.contains(first.name),
            "Description should contain device name")
        #expect(desc.contains(first.uid),
            "Description should contain device UID")
    }
}
