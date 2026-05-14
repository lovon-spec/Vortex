// FWCfgTests.swift -- Unit tests for QEMU fw_cfg helpers.
// VortexHVTests

import Foundation
import Testing
@testable import VortexHV

@Suite("FWCfg")
struct FWCfgTests {
    @Test("QEMU PCI virtio-blk boot paths match EDK2 bootorder syntax")
    func qemuPCIVirtioBlockBootPath() {
        #expect(FWCfgDevice.qemuPCIVirtioBlockBootPath(slot: 3) == "/pci@i0cf8/scsi@3/disk@0,0")
        #expect(FWCfgDevice.qemuPCIVirtioBlockBootPath(slot: 10, function: 2) == "/pci@i0cf8/scsi@a,2/disk@0,0")
    }

    @Test("bootorder file is newline-separated and NUL-terminated")
    func qemuBootOrderPayload() {
        let fwCfg = FWCfgDevice()
        let paths = [
            FWCfgDevice.qemuPCIVirtioBlockBootPath(slot: 3),
            FWCfgDevice.qemuPCIVirtioBlockBootPath(slot: 4),
        ]
        let selector = fwCfg.addQEMUBootOrder(paths: paths)

        select(selector, on: fwCfg)
        let payload = readBytes(from: fwCfg, count: paths.joined(separator: "\n").utf8.count + 2)

        #expect(payload == Array("/pci@i0cf8/scsi@3/disk@0,0\n/pci@i0cf8/scsi@4/disk@0,0\n\0".utf8))
    }

    @Test("bootorder is listed in the fw_cfg file directory")
    func qemuBootOrderDirectoryEntry() {
        let fwCfg = FWCfgDevice()
        let selector = fwCfg.addQEMUBootOrder(paths: [
            FWCfgDevice.qemuPCIVirtioBlockBootPath(slot: 3),
        ])

        select(FWCfgKey.fileDir.rawValue, on: fwCfg)
        let directory = readBytes(from: fwCfg, count: 68)

        #expect(directory[0..<4].elementsEqual([0, 0, 0, 1]))
        #expect(UInt16(directory[8]) << 8 | UInt16(directory[9]) == selector)

        let nameBytes = directory[12..<68].prefix { $0 != 0 }
        #expect(String(decoding: nameBytes, as: UTF8.self) == "bootorder")
    }

    private func readBytes(from fwCfg: FWCfgDevice, count: Int) -> [UInt8] {
        (0..<count).map { _ in
            UInt8(truncatingIfNeeded: fwCfg.mmioRead(offset: 0x00, size: 1))
        }
    }

    private func select(_ selector: UInt16, on fwCfg: FWCfgDevice) {
        fwCfg.mmioWrite(offset: 0x08, size: 2, value: UInt64(selector.bigEndian))
    }
}
