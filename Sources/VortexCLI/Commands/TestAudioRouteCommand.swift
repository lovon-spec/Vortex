// TestAudioRouteCommand.swift — Validate host-side audio routing independently.
// VortexCLI
//
// Tests the VortexAudio module end-to-end without any VM involvement:
//   1. Resolve a device name to an AudioDeviceID via AudioDeviceEnumerator.
//   2. Create an AudioOutputUnit targeting that specific device (not system default).
//   3. Generate a 440 Hz sine wave test tone and write it into an AudioRingBuffer.
//   4. The AudioOutputUnit render callback reads from the ring buffer and plays.
//
// This proves the entire host-side audio pipeline works before plugging in the
// virtio-snd device emulation layer.
//
// Usage:
//   vortex test-audio-route
//   vortex test-audio-route --device "BlackHole 16ch" --duration 5
//   vortex test-audio-route --device "MacBook Pro Speakers" --frequency 880 --duration 3

import ArgumentParser
import Foundation

import VortexAudio

struct TestAudioRouteCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "test-audio-route",
        abstract: "Test host-side audio routing with a sine wave tone.",
        discussion: """
            Exercises the VortexAudio pipeline independently of any VM. \
            Enumerates host audio devices, resolves the target by name, \
            creates a HAL AudioUnit routed to that specific device, generates \
            a test tone, pushes it through an AudioRingBuffer, and plays for \
            the requested duration.

            Verify output via Audio MIDI Setup level meters or by listening.
            """
    )

    @Option(
        name: .long,
        help: "Target output device name (must be an exact match)."
    )
    var device: String = "BlackHole 16ch"

    @Option(
        name: .long,
        help: "Duration in seconds to play the test tone."
    )
    var duration: Int = 5

    @Option(
        name: .long,
        help: "Tone frequency in Hz (default 440 = concert A)."
    )
    var frequency: Double = 440.0

    @Option(
        name: .long,
        help: "Amplitude from 0.0 to 1.0 (default 0.3)."
    )
    var amplitude: Double = 0.3

    @Option(
        name: .long,
        help: "Sample rate in Hz (default 48000)."
    )
    var sampleRate: Double = 48000.0

    @Flag(
        name: .long,
        help: "List all audio devices and exit."
    )
    var listDevices: Bool = false

    // MARK: - Run

    func run() throws {
        // -----------------------------------------------------------------
        // Step 1: Enumerate audio devices.
        // -----------------------------------------------------------------
        let enumerator = AudioDeviceEnumerator()
        let allDevices: [AudioHostDevice]
        do {
            allDevices = try enumerator.allDevices()
        } catch {
            print("[error] Failed to enumerate audio devices: \(error)")
            throw ExitCode.failure
        }

        if listDevices {
            printDeviceList(allDevices)
            return
        }

        print("[test-audio-route] Audio Routing Validation")
        print("============================================")
        print("")
        print("[devices] Found \(allDevices.count) audio device(s):")
        for dev in allDevices {
            let marker = (dev.name == device && dev.isOutput) ? " <-- target" : ""
            print("  - \(dev)\(marker)")
        }
        print("")

        // -----------------------------------------------------------------
        // Step 2: Resolve the target device by name.
        // -----------------------------------------------------------------
        guard let targetDevice = allDevices.first(where: { $0.name == device && $0.isOutput }) else {
            print("[error] Output device '\(device)' not found.")
            print("")
            print("Available output devices:")
            for dev in allDevices.filter(\.isOutput) {
                print("  - \"\(dev.name)\" (id=\(dev.deviceID), uid=\(dev.uid))")
            }
            print("")
            print("Specify a device with:")
            print("  vortex test-audio-route --device \"MacBook Pro Speakers\"")
            throw ExitCode.failure
        }

        print("[route] Target: \(targetDevice.name) (ID: \(targetDevice.deviceID), UID: \(targetDevice.uid))")
        print("[route] Format: \(Int(sampleRate)) Hz, stereo Float32, interleaved")
        print("[route] Tone:   \(frequency) Hz sine wave, amplitude \(amplitude)")
        print("[route] Duration: \(duration) second(s)")
        print("")

        // -----------------------------------------------------------------
        // Step 3: Create the AudioOutputUnit routed to the target device.
        //
        // This creates a HAL AudioUnit with:
        //   - kAudioOutputUnitProperty_CurrentDevice set to targetDevice.deviceID
        //   - A render callback that reads from the internal AudioRingBuffer
        //   - The unit is initialized but NOT yet started
        // -----------------------------------------------------------------
        let outputUnit: AudioOutputUnit
        do {
            outputUnit = try AudioOutputUnit(
                deviceID: targetDevice.deviceID,
                sampleRate: Float64(sampleRate),
                channels: 2,
                bitDepth: 32,
                bufferFrames: Int(sampleRate)  // 1 second buffer
            )
        } catch {
            print("[error] Failed to create AudioOutputUnit: \(error)")
            throw ExitCode.failure
        }

        print("[audio] AudioOutputUnit created and initialized.")
        print("[audio] Ring buffer capacity: \(outputUnit.ringBuffer.capacity) samples " +
              "(\(outputUnit.ringBuffer.capacity / outputUnit.ringBuffer.channelCount) frames)")
        print("")

        // -----------------------------------------------------------------
        // Step 4: Pre-fill the ring buffer with the test tone.
        //
        // We generate interleaved stereo Float32 samples of a sine wave.
        // The same signal goes to both L and R channels.
        // -----------------------------------------------------------------
        let totalFrames = Int(sampleRate) * duration
        let channelCount = 2
        let totalSamples = totalFrames * channelCount

        // Allocate a generation buffer. We write in chunks that fit the ring
        // buffer to avoid requiring totalSamples of contiguous memory for
        // very long durations.
        let chunkFrames = min(totalFrames, outputUnit.ringBuffer.capacity / channelCount)
        let chunkSamples = chunkFrames * channelCount
        let chunkBuffer = UnsafeMutablePointer<Float>.allocate(capacity: chunkSamples)
        defer { chunkBuffer.deallocate() }

        // Pre-fill as much of the ring buffer as possible before starting playback.
        let prefillFrames = min(totalFrames, outputUnit.ringBuffer.framesAvailableForWrite)
        var generatedFrames = 0
        generatedFrames = generateAndWrite(
            to: outputUnit.ringBuffer,
            buffer: chunkBuffer,
            chunkSamples: chunkSamples,
            channelCount: channelCount,
            startFrame: generatedFrames,
            frameCount: prefillFrames,
            sampleRate: sampleRate,
            frequency: frequency,
            amplitude: amplitude
        )

        print("[tone] Pre-filled \(generatedFrames) frames into ring buffer.")
        print("[tone] Total frames to generate: \(totalFrames)")
        print("")

        // -----------------------------------------------------------------
        // Step 5: Start the AudioOutputUnit.
        //
        // From this point, the CoreAudio render callback fires on its
        // real-time thread, pulling data from the ring buffer.
        // -----------------------------------------------------------------
        do {
            try outputUnit.start()
        } catch {
            print("[error] Failed to start AudioOutputUnit: \(error)")
            throw ExitCode.failure
        }

        print("[play] Started. Playing \(frequency) Hz tone for \(duration) seconds...")
        print("[play] Verify output in Audio MIDI Setup or by listening on \(targetDevice.name).")
        print("")

        // -----------------------------------------------------------------
        // Step 6: Feed the ring buffer in a loop for the duration.
        //
        // The render callback drains frames; we keep generating and writing
        // new frames to avoid underrun. We sleep briefly between writes to
        // avoid busy-waiting. This mirrors what the virtio-snd device
        // emulation layer will do in production.
        // -----------------------------------------------------------------
        let startTime = Date()
        var lastReportTime = startTime
        var underrunWarnings = 0

        while generatedFrames < totalFrames {
            let remaining = totalFrames - generatedFrames
            let writable = outputUnit.ringBuffer.framesAvailableForWrite
            let toWrite = min(remaining, min(writable, chunkFrames))

            if toWrite > 0 {
                generatedFrames = generateAndWrite(
                    to: outputUnit.ringBuffer,
                    buffer: chunkBuffer,
                    chunkSamples: chunkSamples,
                    channelCount: channelCount,
                    startFrame: generatedFrames,
                    frameCount: toWrite,
                    sampleRate: sampleRate,
                    frequency: frequency,
                    amplitude: amplitude
                )
            } else {
                // Ring buffer is full -- the render callback hasn't consumed
                // enough yet. Sleep briefly to let it drain.
                Thread.sleep(forTimeInterval: 0.005)
            }

            // Check for underrun (ring buffer completely empty while we still
            // have frames to generate).
            if outputUnit.ringBuffer.framesAvailableForRead == 0 && generatedFrames < totalFrames {
                underrunWarnings += 1
            }

            // Periodic progress report (every second).
            let now = Date()
            if now.timeIntervalSince(lastReportTime) >= 1.0 {
                let elapsed = Int(now.timeIntervalSince(startTime))
                let buffered = outputUnit.ringBuffer.framesAvailableForRead
                print("  [\(elapsed)s] Generated: \(generatedFrames)/\(totalFrames) frames, " +
                      "buffered: \(buffered) frames")
                lastReportTime = now
            }
        }

        // Wait for the ring buffer to drain (render callback consumes remaining frames).
        let drainStart = Date()
        let drainTimeout: TimeInterval = 3.0
        while outputUnit.ringBuffer.framesAvailableForRead > 0 {
            if Date().timeIntervalSince(drainStart) > drainTimeout {
                print("[warn] Ring buffer did not fully drain within \(Int(drainTimeout))s timeout.")
                break
            }
            Thread.sleep(forTimeInterval: 0.010)
        }

        // -----------------------------------------------------------------
        // Step 7: Stop and report.
        // -----------------------------------------------------------------
        outputUnit.stop()

        let totalElapsed = Date().timeIntervalSince(startTime)

        print("")
        print("=== RESULT ===")
        print("")
        print("[done] Audio routing test completed.")
        print("  Device:        \(targetDevice.name) (ID: \(targetDevice.deviceID))")
        print("  Format:        \(Int(sampleRate)) Hz, stereo Float32")
        print("  Tone:          \(frequency) Hz sine wave")
        print("  Duration:      \(String(format: "%.1f", totalElapsed))s actual / \(duration)s requested")
        print("  Frames played: \(generatedFrames) (\(totalSamples) samples)")
        if underrunWarnings > 0 {
            print("  Underruns:     \(underrunWarnings) (ring buffer emptied during playback)")
        } else {
            print("  Underruns:     0")
        }
        print("")
        print("If you heard the tone (or saw level meters move in Audio MIDI Setup),")
        print("the VortexAudio pipeline is working correctly for device-specific routing.")
    }

    // MARK: - Private helpers

    /// Generates sine wave samples and writes them into the ring buffer.
    ///
    /// - Returns: The new total number of frames generated (startFrame + frameCount).
    private func generateAndWrite(
        to ringBuffer: AudioRingBuffer,
        buffer: UnsafeMutablePointer<Float>,
        chunkSamples: Int,
        channelCount: Int,
        startFrame: Int,
        frameCount: Int,
        sampleRate: Double,
        frequency: Double,
        amplitude: Double
    ) -> Int {
        let samplesToGenerate = frameCount * channelCount
        precondition(samplesToGenerate <= chunkSamples,
                     "Requested \(samplesToGenerate) samples but chunk buffer holds \(chunkSamples)")

        let amp = Float(amplitude)
        let twoPiF = 2.0 * Double.pi * frequency

        for frame in 0..<frameCount {
            let globalFrame = startFrame + frame
            let sample = Float(sin(twoPiF * Double(globalFrame) / sampleRate)) * amp
            // Interleaved stereo: L, R, L, R, ...
            buffer[frame * channelCount]     = sample  // Left
            buffer[frame * channelCount + 1] = sample  // Right
        }

        let src = UnsafeBufferPointer(start: buffer, count: samplesToGenerate)
        ringBuffer.write(src, frameCount: frameCount)

        return startFrame + frameCount
    }

    /// Prints a formatted device list and exits.
    private func printDeviceList(_ devices: [AudioHostDevice]) {
        if devices.isEmpty {
            print("No audio devices found.")
            return
        }

        print("Audio Devices (\(devices.count)):")
        print("")

        let outputDevices = devices.filter(\.isOutput)
        let inputDevices = devices.filter(\.isInput)

        if !outputDevices.isEmpty {
            print("  Output devices:")
            for dev in outputDevices {
                print("    \"\(dev.name)\"  (id=\(dev.deviceID), uid=\(dev.uid))")
            }
            print("")
        }

        if !inputDevices.isEmpty {
            print("  Input devices:")
            for dev in inputDevices {
                print("    \"\(dev.name)\"  (id=\(dev.deviceID), uid=\(dev.uid))")
            }
            print("")
        }
    }
}
