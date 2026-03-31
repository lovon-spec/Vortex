// AudioInterceptorTests.swift — Tests for the CoreAudio interception layer.
// VortexInterceptionTests

import Testing
@testable import VortexInterception

// MARK: - AudioInterceptor state tests

/// Tests for AudioInterceptor's installation lifecycle and state management.
/// These tests verify the hook installation/uninstall logic without actually
/// intercepting CoreAudio calls (which would require a running VZ VM).
@Suite("AudioInterceptor State Management")
struct AudioInterceptorStateTests {

    @Test("Initial state: not installed")
    func initialState() {
        // Ensure clean state (uninstall if a prior test left hooks active).
        AudioInterceptor.uninstall()

        #expect(!AudioInterceptor.isInstalled)
        let info = AudioInterceptor.diagnosticInfo
        #expect(!info.isInstalled)
        #expect(info.trackedUnitCount == 0)
        #expect(info.instanceNewCallCount == 0)
        #expect(info.deviceRedirectCount == 0)
    }

    @Test("Install and uninstall round-trip")
    func installUninstallRoundTrip() throws {
        // Clean slate.
        AudioInterceptor.uninstall()

        // Install with a dummy device ID (1 is unlikely to be a real device,
        // but we are only testing the install/uninstall state machine here).
        try AudioInterceptor.install(targetOutputDeviceID: 1)
        #expect(AudioInterceptor.isInstalled)

        let info = AudioInterceptor.diagnosticInfo
        #expect(info.targetOutputDeviceID == 1)
        #expect(info.targetInputDeviceID == 0)

        // Uninstall.
        AudioInterceptor.uninstall()
        #expect(!AudioInterceptor.isInstalled)
    }

    @Test("Double install throws alreadyInstalled")
    func doubleInstallThrows() throws {
        AudioInterceptor.uninstall()

        try AudioInterceptor.install(targetOutputDeviceID: 42)
        defer { AudioInterceptor.uninstall() }

        #expect(throws: InterceptionError.self) {
            try AudioInterceptor.install(targetOutputDeviceID: 99)
        }
    }

    @Test("Uninstall when not installed is safe")
    func uninstallWhenNotInstalled() {
        AudioInterceptor.uninstall()

        // Should not crash or throw.
        AudioInterceptor.uninstall()
        #expect(!AudioInterceptor.isInstalled)
    }

    @Test("DiagnosticInfo description is non-empty")
    func diagnosticInfoDescription() {
        AudioInterceptor.uninstall()
        let info = AudioInterceptor.diagnosticInfo
        #expect(!info.description.isEmpty)
        #expect(info.description.contains("AudioInterceptor"))
    }

    @Test("Install with input device ID")
    func installWithInputDevice() throws {
        AudioInterceptor.uninstall()

        try AudioInterceptor.install(
            targetOutputDeviceID: 10,
            targetInputDeviceID: 20
        )
        defer { AudioInterceptor.uninstall() }

        let info = AudioInterceptor.diagnosticInfo
        #expect(info.targetOutputDeviceID == 10)
        #expect(info.targetInputDeviceID == 20)
    }
}

// MARK: - InterceptionError tests

@Suite("InterceptionError")
struct InterceptionErrorTests {

    @Test("Error descriptions are meaningful")
    func errorDescriptions() {
        let errors: [InterceptionError] = [
            .alreadyInstalled,
            .rebindFailed(code: -1),
            .invalidDeviceID(0),
        ]

        for error in errors {
            #expect(!error.description.isEmpty)
        }

        #expect(InterceptionError.alreadyInstalled.description
            .contains("already installed"))
        #expect(InterceptionError.rebindFailed(code: -1).description
            .contains("-1"))
        #expect(InterceptionError.invalidDeviceID(0).description
            .contains("0"))
    }
}
