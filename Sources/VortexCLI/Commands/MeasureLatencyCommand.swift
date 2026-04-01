// MeasureLatencyCommand.swift -- Measure audio pipeline latency.
// VortexCLI
//
// Measures the one-way output latency of the Vortex audio pipeline: the time
// from when a PCM_OUTPUT message arrives at the host bridge (vsock) to when
// the AudioOutputUnit's render callback reads that data from the ring buffer.
//
// This is a SHIP BLOCKER metric for the productization phase. The pass criteria:
//   - Command reports latency statistics: PASS
//   - One-way output latency <10ms at 48kHz: PASS
//   - Buffer depth is stable (not growing or draining): PASS
//
// There are two modes:
//
//   1. **Standalone mode** (default): No VM required. Sets up an AudioOutputUnit
//      with a ring buffer, feeds synthetic PCM on a timer (simulating bridge
//      writes), and measures the render callback latency. This validates the
//      host-side audio pipeline in isolation.
//
//   2. **VM mode** (--vm <uuid>): Starts a real VM with the vsock audio bridge,
//      waits for the guest daemon to connect, and measures live latency. This
//      requires a running guest with the Vortex audio daemon installed.
//
// Usage:
//   vortex measure-latency
//   vortex measure-latency --device "BlackHole 16ch" --duration 10
//   vortex measure-latency --vm <uuid> --output-device "BlackHole 16ch" --duration 30

import ArgumentParser
import Darwin
import Foundation

import VortexAudio

struct MeasureLatencyCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "measure-latency",
        abstract: "Measure audio pipeline latency through the Vortex audio path.",
        discussion: """
            Measures the one-way output latency: time from PCM data arriving at \
            the host bridge to the AudioUnit render callback reading it from the \
            ring buffer.

            In standalone mode (no --vm), generates synthetic PCM to exercise \
            the host-side pipeline without a guest VM. In VM mode, measures \
            live latency from the vsock audio bridge.

            Reports min, max, mean, p50, p95, p99 latency and buffer depth \
            statistics. Pass criteria: p95 < 10ms, stable buffer depth.
            """
    )

    // MARK: - Options

    @Option(
        name: .long,
        help: "Target output device name (default: BlackHole 16ch)."
    )
    var device: String = "BlackHole 16ch"

    @Option(
        name: .long,
        help: "Measurement duration in seconds."
    )
    var duration: Int = 10

    @Option(
        name: .long,
        help: "Sample rate in Hz."
    )
    var sampleRate: Double = 48000.0

    @Option(
        name: .long,
        help: "Report interval in seconds (prints intermediate stats)."
    )
    var reportInterval: Int = 2

    @Flag(
        name: .long,
        help: "List all audio devices and exit."
    )
    var listDevices: Bool = false

    // MARK: - Run

    func run() throws {
        // Device listing shortcut.
        if listDevices {
            try printDeviceList()
            return
        }

        try runStandaloneMode()
    }

    // MARK: - Standalone Mode

    /// Measures latency using a synthetic PCM source (no VM needed).
    ///
    /// Sets up:
    ///   1. An AudioOutputUnit targeting the specified device.
    ///   2. A LatencyCollector shared between the write side and render callback.
    ///   3. A timer that writes PCM chunks into the ring buffer (simulating
    ///      the vsock bridge) and stores write timestamps in the collector.
    ///   4. The render callback reads from the ring buffer and records
    ///      latency samples in the collector.
    ///   5. After the measurement duration, drains all samples and prints stats.
    private func runStandaloneMode() throws {
        print("[measure-latency] Vortex Audio Pipeline Latency Measurement")
        print("============================================================")
        print("")
        print("Mode: standalone (synthetic PCM source)")
        print("")

        // Step 1: Resolve the target device.
        let enumerator = AudioDeviceEnumerator()
        let allDevices = try enumerator.allDevices()
        guard let targetDevice = allDevices.first(where: {
            $0.name == device && $0.isOutput
        }) else {
            print("[error] Output device '\(device)' not found.")
            print("")
            print("Available output devices:")
            for dev in allDevices.filter(\.isOutput) {
                print("  - \"\(dev.name)\" (uid=\(dev.uid))")
            }
            throw ExitCode.failure
        }

        print("Device:      \(targetDevice.name) (uid=\(targetDevice.uid))")
        print("Format:      \(Int(sampleRate)) Hz, stereo Float32")
        print("Duration:    \(duration) seconds")
        print("Report every \(reportInterval) seconds")
        print("")

        // Step 2: Create the latency collector and output unit.
        let collector = LatencyCollector(capacity: 16384)
        let converter = MachTimeConverter()

        let outputUnit = try AudioOutputUnit(
            deviceID: targetDevice.deviceID,
            sampleRate: Float64(sampleRate),
            channels: 2,
            bitDepth: 32,
            bufferFrames: Int(sampleRate / 10) // 100ms ring buffer
        )
        outputUnit.latencyCollector = collector
        collector.isEnabled = true

        // Step 3: Pre-fill ring buffer with a small amount of silence to prime
        // the pipeline (avoids immediate underrun at startup).
        let prefillFrames = 512
        let prefillSamples = prefillFrames * 2 // stereo
        let prefillBuf = UnsafeMutablePointer<Float>.allocate(capacity: prefillSamples)
        defer { prefillBuf.deallocate() }
        prefillBuf.initialize(repeating: 0.0, count: prefillSamples)
        let prefillSrc = UnsafeBufferPointer(start: prefillBuf, count: prefillSamples)
        outputUnit.ringBuffer.write(prefillSrc, frameCount: prefillFrames)

        // Step 4: Start the output unit.
        try outputUnit.start()
        print("[audio] Output unit started.")

        // Step 5: Start a write timer that feeds PCM and records timestamps.
        // We write 480 frames (~10ms at 48kHz) every 10ms, matching a typical
        // guest daemon send rate.
        let writeInterval: TimeInterval = 0.010  // 10ms
        let framesPerWrite = Int(sampleRate * writeInterval)
        let samplesPerWrite = framesPerWrite * 2 // stereo
        let writeBuf = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerWrite)
        defer { writeBuf.deallocate() }

        // Generate a low-level sine wave to distinguish from silence in any
        // audio monitoring. Amplitude 0.05 -- barely audible.
        let twoPi = 2.0 * Double.pi * 440.0
        var writePhase = 0

        let writeQueue = DispatchQueue(
            label: "com.vortex.latency-measure.write",
            qos: .userInteractive
        )
        let writeTimer = DispatchSource.makeTimerSource(queue: writeQueue)
        writeTimer.schedule(
            deadline: .now() + writeInterval,
            repeating: writeInterval,
            leeway: .milliseconds(1)
        )
        writeTimer.setEventHandler { [weak outputUnit] in
            guard let outputUnit else { return }

            // Generate PCM.
            for i in 0..<framesPerWrite {
                let sample = Float(sin(twoPi * Double(writePhase + i) / sampleRate)) * 0.05
                writeBuf[i * 2] = sample
                writeBuf[i * 2 + 1] = sample
            }
            writePhase += framesPerWrite

            // Write to ring buffer.
            let src = UnsafeBufferPointer(start: writeBuf, count: samplesPerWrite)
            outputUnit.ringBuffer.write(src, frameCount: framesPerWrite)

            // Record write timestamp (same as VsockAudioBridge does).
            collector.storeWriteTimestamp()
        }
        writeTimer.resume()
        print("[write] Synthetic PCM writer started (\(framesPerWrite) frames every \(Int(writeInterval * 1000))ms).")
        print("")

        // Step 6: Collect samples for the measurement duration.
        var allSamples: [LatencySample] = []
        allSamples.reserveCapacity(duration * 100) // ~100 callbacks/sec at 48kHz/512

        let startTime = Date()
        var lastReportTime = startTime
        var intervalSamples: [LatencySample] = []

        print("[measuring] Collecting latency samples for \(duration) seconds...")
        print("")

        while Date().timeIntervalSince(startTime) < Double(duration) {
            Thread.sleep(forTimeInterval: 0.050) // 50ms poll interval

            collector.drainSamples(into: &allSamples)

            // Periodic intermediate report.
            let now = Date()
            if now.timeIntervalSince(lastReportTime) >= Double(reportInterval) {
                let elapsed = Int(now.timeIntervalSince(startTime))

                // Compute stats on samples collected since last report.
                let newSamples = Array(allSamples.suffix(from: intervalSamples.count))
                intervalSamples = allSamples

                if let stats = LatencyCollector.computeStatistics(
                    from: newSamples, converter: converter
                ) {
                    print("  [\(elapsed)s] \(newSamples.count) samples: " +
                          "mean=\(String(format: "%.3f", stats.meanMs))ms " +
                          "p95=\(String(format: "%.3f", stats.p95Ms))ms " +
                          "buf=\(stats.bufferFramesMin)-\(stats.bufferFramesMax) frames")
                } else {
                    print("  [\(elapsed)s] No samples collected (underrun or no data)")
                }
                lastReportTime = now
            }
        }

        // Step 7: Stop and collect remaining samples.
        writeTimer.cancel()
        collector.isEnabled = false

        // Let a few more callbacks fire to drain.
        Thread.sleep(forTimeInterval: 0.100)
        collector.drainSamples(into: &allSamples)

        outputUnit.stop()

        // Step 8: Compute and print final statistics.
        print("")
        print("=== LATENCY MEASUREMENT RESULTS ===")
        print("")

        guard let stats = LatencyCollector.computeStatistics(
            from: allSamples, converter: converter
        ) else {
            print("[error] No latency samples were collected.")
            print("")
            print("This can happen if:")
            print("  - The output device is not accepting audio (check Audio MIDI Setup)")
            print("  - The ring buffer underran continuously (no data to read)")
            throw ExitCode.failure
        }

        print(stats)
        print("")

        // Pass/fail assessment.
        let passLatency = stats.meetsLatencyTarget
        let passBuffer = stats.bufferIsStable
        let passOverall = passLatency && passBuffer

        print("--- PASS/FAIL ---")
        print("")
        print("  Output latency p95 < 10ms:  \(passLatency ? "PASS" : "FAIL") " +
              "(\(String(format: "%.3f", stats.p95Ms))ms)")
        print("  Buffer depth stable:        \(passBuffer ? "PASS" : "FAIL") " +
              "(range: \(stats.bufferFramesMin)-\(stats.bufferFramesMax))")
        print("  Overall:                    \(passOverall ? "PASS" : "FAIL")")
        print("")

        if !passOverall {
            throw ExitCode.failure
        }
    }

    // MARK: - Helpers

    private func printDeviceList() throws {
        let enumerator = AudioDeviceEnumerator()
        let allDevices = try enumerator.allDevices()

        if allDevices.isEmpty {
            print("No audio devices found.")
            return
        }

        print("Audio Devices (\(allDevices.count)):")
        print("")

        let outputDevices = allDevices.filter(\.isOutput)
        let inputDevices = allDevices.filter(\.isInput)

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
