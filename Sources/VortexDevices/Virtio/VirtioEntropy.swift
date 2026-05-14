// VirtioEntropy.swift -- VirtIO entropy device emulation.
// VortexDevices

import Foundation

/// VirtIO entropy source backed by the host system RNG.
///
/// The virtio-rng device has a single request queue. Each request consists of
/// one or more device-writable buffers; the device fills them with random bytes
/// and posts the total number of bytes written.
public final class VirtioEntropyDevice: VirtioDeviceBase, @unchecked Sendable {
    private var rng = SystemRandomNumberGenerator()

    public init(defaultQueueSize: UInt16 = 64) {
        super.init(
            deviceType: .entropy,
            numQueues: 1,
            deviceFeatures: 0,
            configSize: 0,
            defaultQueueSize: defaultQueueSize
        )
    }

    public override func handleQueueNotification(queueIndex: Int) {
        guard queueIndex == 0, queueIndex < queues.count else { return }
        let queue = queues[queueIndex]

        while let chain = queue.nextAvailableChain() {
            var written = 0
            for descriptor in chain where descriptor.isDeviceWritable {
                let data = randomData(count: Int(descriptor.len))
                chain.writeBuffer(data, to: descriptor)
                written += data.count
            }
            queue.addUsed(headIndex: chain.headIndex, length: UInt32(written))
            signalUsedBuffers(queueIndex: queueIndex)
        }
    }

    private func randomData(count: Int) -> Data {
        guard count > 0 else { return Data() }

        var data = Data(count: count)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            var offset = 0
            while offset + MemoryLayout<UInt64>.size <= count {
                var value = rng.next()
                withUnsafeBytes(of: &value) { bytes in
                    for i in 0..<MemoryLayout<UInt64>.size {
                        base[offset + i] = bytes[i]
                    }
                }
                offset += MemoryLayout<UInt64>.size
            }

            if offset < count {
                var value = rng.next()
                withUnsafeBytes(of: &value) { bytes in
                    for i in 0..<(count - offset) {
                        base[offset + i] = bytes[i]
                    }
                }
            }
        }
        return data
    }
}
