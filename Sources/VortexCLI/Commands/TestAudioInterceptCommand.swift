// TestAudioInterceptCommand.swift — Track A validation: is VZ audio in-process?
// VortexCLI
//
// This command is the go/no-go test for Track A. It installs AudioInterceptor
// hooks (via fishhook), then creates a minimal Virtualization.framework config
// with VZVirtioSoundDeviceConfiguration. We observe whether VZ creates
// AudioUnit instances in our process address space.
//
// If hooks intercept AudioComponentInstanceNew calls: Track A is viable.
// If no interceptions after the timeout: VZ audio runs in the XPC service
// (com.apple.Virtualization.VirtualMachine) and Track A is NOT viable.
//
// Usage:
//   vortex test-audio-intercept
//   vortex test-audio-intercept --device "BlackHole 16ch"
//   vortex test-audio-intercept --timeout 20

import ArgumentParser
import Foundation
import os

import VortexAudio
import VortexInterception

struct TestAudioInterceptCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "test-audio-intercept",
        abstract: "Track A validation: test whether VZ audio runs in-process.",
        discussion: """
            Installs CoreAudio function hooks via fishhook, then creates a \
            Virtualization.framework VM configuration with VZVirtioSoundDeviceConfiguration. \
            Monitors for intercepted AudioComponentInstanceNew and AudioUnitSetProperty \
            calls to determine whether VZ's audio path runs in our process or in its \
            XPC service.

            If hooks fire: Track A (CoreAudio interception) is viable.
            If no hooks fire: VZ audio is out-of-process and Track A is NOT viable.
            """
    )

    @Option(
        name: .long,
        help: "Target output device name to redirect to (must be an exact match)."
    )
    var device: String = "BlackHole 16ch"

    @Option(
        name: .long,
        help: "Seconds to wait for VZ audio initialization before declaring result."
    )
    var timeout: Int = 10

    @Flag(
        name: .long,
        help: "Also attempt to start the VM (requires a scratch disk image)."
    )
    var withStart: Bool = false

    @Option(
        name: .long,
        help: "Path to a scratch disk image for --with-start mode. Created if missing."
    )
    var scratchDisk: String = "/tmp/vortex-tracka-scratch.img"

    // MARK: - Run

    func run() throws {
        let logger = Logger(
            subsystem: "com.vortex.cli",
            category: "TestAudioIntercept"
        )

        print("[Track A] Audio Interception Validation Test")
        print("=============================================")
        print("")

        // ---------------------------------------------------------------
        // Step 1: Enumerate audio devices and resolve the target.
        // ---------------------------------------------------------------
        let enumerator = AudioDeviceEnumerator()
        let allDevices: [AudioHostDevice]
        do {
            allDevices = try enumerator.allDevices()
        } catch {
            print("[ERROR] Failed to enumerate audio devices: \(error)")
            throw ExitCode.failure
        }

        print("[AudioDevices] Found \(allDevices.count) device(s):")
        for dev in allDevices {
            print("  - \(dev)")
        }
        print("")

        guard let targetDevice = allDevices.first(where: { $0.name == device && $0.isOutput }) else {
            print("[ERROR] Output device '\(device)' not found.")
            print("")
            print("Available output devices:")
            for dev in allDevices.filter(\.isOutput) {
                print("  - \"\(dev.name)\" (id=\(dev.deviceID), uid=\(dev.uid))")
            }
            print("")
            print("If you don't have BlackHole installed, specify a different device:")
            print("  vortex test-audio-intercept --device \"MacBook Pro Speakers\"")
            throw ExitCode.failure
        }

        print("[AudioInterceptor] Target output device: \(targetDevice.name) (ID: \(targetDevice.deviceID))")
        print("")

        // ---------------------------------------------------------------
        // Step 2: Install AudioInterceptor hooks.
        // ---------------------------------------------------------------
        do {
            try AudioInterceptor.install(
                targetOutputDeviceID: targetDevice.deviceID
            )
        } catch {
            print("[ERROR] Failed to install audio hooks: \(error)")
            throw ExitCode.failure
        }
        print("[AudioInterceptor] Hooks installed successfully.")
        print("")

        defer {
            AudioInterceptor.uninstall()
            print("")
            print("[AudioInterceptor] Hooks uninstalled.")
        }

        // ---------------------------------------------------------------
        // Step 3: Snapshot the initial diagnostic counters.
        // ---------------------------------------------------------------
        let preInfo = AudioInterceptor.diagnosticInfo
        print("[AudioInterceptor] Pre-VZ state: \(preInfo)")
        print("")

        // ---------------------------------------------------------------
        // Step 4: Create a VZ config with audio devices.
        //
        // We use the Virtualization framework directly here rather than going
        // through TrackAVMManager because we want the lightest possible config.
        // We are testing whether VZ's audio init runs in-process — we do NOT
        // need a bootable VM.
        // ---------------------------------------------------------------
        print("[VZ] Creating minimal VM configuration with VZVirtioSoundDeviceConfiguration...")

        let vzCreationResult = createVZConfiguration(logger: logger)
        switch vzCreationResult {
        case .success(let description):
            print("[VZ] \(description)")
        case .failure(let error):
            print("[VZ] Configuration failed: \(error)")
            print("[VZ] (This may be expected — we only need VZ to attempt audio init)")
        }
        print("")

        // Check if creation alone triggered any hooks.
        let postCreateInfo = AudioInterceptor.diagnosticInfo
        if postCreateInfo.instanceNewCallCount > preInfo.instanceNewCallCount {
            let newCalls = postCreateInfo.instanceNewCallCount - preInfo.instanceNewCallCount
            print("[AudioInterceptor] ** VZ config creation triggered \(newCalls) AudioUnit creation(s) **")
        } else {
            print("[AudioInterceptor] No AudioUnit creation during VZ config phase.")
        }

        // ---------------------------------------------------------------
        // Step 5: Optionally attempt to start the VM.
        //
        // VZ may defer AudioUnit creation to the start phase. In --with-start
        // mode, we create a scratch disk image and attempt to start a Linux VM.
        // It will fail to boot (no kernel), but VZ may still initialize audio.
        // ---------------------------------------------------------------
        if withStart {
            print("")
            print("[VZ] --with-start: Attempting to start VM (expected to fail boot)...")
            attemptVMStart(scratchDiskPath: scratchDisk, logger: logger)
        }

        // ---------------------------------------------------------------
        // Step 6: Wait for the timeout, polling diagnostics periodically.
        // ---------------------------------------------------------------
        print("")
        print("[Track A] Monitoring for \(timeout) seconds...")
        print("")

        let startTime = Date()
        var lastCount: UInt64 = AudioInterceptor.diagnosticInfo.instanceNewCallCount
        var lastRedirects: UInt64 = AudioInterceptor.diagnosticInfo.deviceRedirectCount

        while Date().timeIntervalSince(startTime) < Double(timeout) {
            Thread.sleep(forTimeInterval: 1.0)

            let info = AudioInterceptor.diagnosticInfo
            let elapsed = Int(Date().timeIntervalSince(startTime))

            if info.instanceNewCallCount != lastCount {
                let delta = info.instanceNewCallCount - lastCount
                print("  [\(elapsed)s] AudioComponentInstanceNew: +\(delta) (total: \(info.instanceNewCallCount))")
                lastCount = info.instanceNewCallCount
            }
            if info.deviceRedirectCount != lastRedirects {
                let delta = info.deviceRedirectCount - lastRedirects
                print("  [\(elapsed)s] Device redirects: +\(delta) (total: \(info.deviceRedirectCount))")
                lastRedirects = info.deviceRedirectCount
            }
        }

        // ---------------------------------------------------------------
        // Step 7: Report results.
        // ---------------------------------------------------------------
        let finalInfo = AudioInterceptor.diagnosticInfo
        let totalNewCalls = finalInfo.instanceNewCallCount - preInfo.instanceNewCallCount
        let totalRedirects = finalInfo.deviceRedirectCount - preInfo.deviceRedirectCount

        print("")
        print("=== RESULTS ===")
        print("")
        print("[AudioInterceptor] Final state: \(finalInfo)")
        print("")
        print("  AudioComponentInstanceNew calls intercepted: \(totalNewCalls)")
        print("  AudioUnitSetProperty redirects:              \(totalRedirects)")
        print("  Tracked AudioUnit instances:                 \(finalInfo.trackedUnitCount)")
        print("")

        if totalNewCalls > 0 {
            print("[Track A] RESULT: VIABLE")
            print("")
            print("  VZ creates AudioUnit instances IN-PROCESS.")
            print("  fishhook-based interception can redirect VZ audio to per-VM devices.")
            if totalRedirects > 0 {
                print("  Device redirection confirmed: \(totalRedirects) property sets redirected")
                print("  to \(targetDevice.name) (ID: \(targetDevice.deviceID)).")
            } else {
                print("  Note: No device property redirections were intercepted.")
                print("  VZ may set the device at a different lifecycle point.")
                print("  This needs further investigation during an actual VM boot.")
            }
        } else {
            print("[Track A] RESULT: NOT VIABLE -- audio path is out of process")
            print("")
            print("  No AudioComponentInstanceNew calls were intercepted after \(timeout)s.")
            print("  VZ's audio likely runs in the com.apple.Virtualization.VirtualMachine")
            print("  XPC service, not in the host process.")
            print("")
            print("  Recommendation: Abandon Track A. Proceed with Track B (vsock audio")
            print("  bridge) or Track B1 (HAL AudioServerPlugin in guest).")
        }
    }
}

// MARK: - VZ Configuration Helpers

/// These are in an extension to keep the imports and VZ usage isolated.
/// We import Virtualization at the function level using @_implementationOnly
/// would be ideal, but since VortexInterception already links Virtualization,
/// we use it through that path.
extension TestAudioInterceptCommand {

    /// Creates a minimal VZ configuration with audio devices.
    /// Returns a description string on success or an error on failure.
    private func createVZConfiguration(logger: Logger) -> Result<String, Error> {
        // We do this on the main thread / current thread since VZ config
        // creation (NOT VZVirtualMachine usage) does not have threading constraints.
        do {
            let config = try VZConfigBuilder.buildMinimalAudioConfig()
            return .success(config)
        } catch {
            return .failure(error)
        }
    }

    /// Attempts to start a VZ VM. This is best-effort: we expect it to fail
    /// (no valid boot image), but VZ may still initialize its audio subsystem.
    private func attemptVMStart(scratchDiskPath: String, logger: Logger) {
        do {
            try VZConfigBuilder.attemptVMStart(
                scratchDiskPath: scratchDiskPath,
                timeout: Double(timeout)
            )
        } catch {
            print("[VZ] VM start result: \(error)")
            print("[VZ] (Expected — checking if audio was initialized)")
        }
    }
}
