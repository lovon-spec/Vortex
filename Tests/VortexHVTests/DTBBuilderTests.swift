// DTBBuilderTests.swift -- Unit tests for generated ARM FDT blobs.
// VortexHVTests

import Testing
import Foundation
@testable import VortexHV

@Suite("DTBBuilder")
struct DTBBuilderTests {
    @Test("FDT header offsets point to the correct blocks")
    func headerOffsets() {
        let dtb = DTBBuilder(cpuCount: 2, ramSize: 512 * 1024 * 1024).build()

        #expect(readBE32(dtb, at: 0) == 0xD00D_FEED)
        #expect(readBE32(dtb, at: 8) == 56)   // off_dt_struct
        #expect(readBE32(dtb, at: 16) == 40)  // off_mem_rsvmap
        #expect(readBE32(dtb, at: 20) == 17)  // version
        #expect(readBE32(dtb, at: 24) == 16)  // last_comp_version
        #expect(readBE32(dtb, at: 36) > 0)    // size_dt_struct

        let totalSize = Int(readBE32(dtb, at: 4))
        let stringsOffset = Int(readBE32(dtb, at: 12))
        let stringsSize = Int(readBE32(dtb, at: 32))
        let structOffset = Int(readBE32(dtb, at: 8))
        let structSize = Int(readBE32(dtb, at: 36))

        #expect(totalSize == dtb.count)
        #expect(stringsOffset == structOffset + structSize)
        #expect(stringsOffset + stringsSize == totalSize)
    }

    @Test("Platform devices reference a real fixed clock provider")
    func platformClockProvider() throws {
        let dtb = DTBBuilder(cpuCount: 2, ramSize: 512 * 1024 * 1024).build()

        let clockFrequency = try #require(fdtProperty(dtb, node: "clk24mhz", property: "clock-frequency"))
        let clockPhandle = try #require(fdtProperty(dtb, node: "clk24mhz", property: "phandle"))
        let uartClocks = try #require(fdtProperty(dtb, node: "uart@9000000", property: "clocks"))
        let rtcClocks = try #require(fdtProperty(dtb, node: "rtc@9010000", property: "clocks"))

        #expect(readBE32(clockFrequency, at: 0) == 24_000_000)
        #expect(readBE32(clockPhandle, at: 0) == 2)
        #expect(readBE32(uartClocks, at: 0) == 2)
        #expect(readBE32(uartClocks, at: 4) == 2)
        #expect(readBE32(rtcClocks, at: 0) == 2)
    }

    @Test("PCI interrupt map matches the Linux OF PCI binding tuple shape")
    func pciInterruptMapShape() throws {
        let dtb = DTBBuilder(
            cpuCount: 2,
            ramSize: 512 * 1024 * 1024,
            includePCIHostBridge: true
        ).build()

        let mask = try #require(fdtProperty(dtb, node: "pcie@10000000", property: "interrupt-map-mask"))
        let map = try #require(fdtProperty(dtb, node: "pcie@10000000", property: "interrupt-map"))

        #expect(readBE32(mask, at: 0) == 0x0000_1800)
        #expect(readBE32(mask, at: 4) == 0)
        #expect(readBE32(mask, at: 8) == 0)
        #expect(readBE32(mask, at: 12) == 7)

        let cellsPerTuple = 10
        let tupleCount = 4 * 4
        #expect(map.count == tupleCount * cellsPerTuple * 4)

        #expect(readBE32(map, at: 0) == 0)
        #expect(readBE32(map, at: 12) == 1) // INTA#
        #expect(readBE32(map, at: 16) == 1) // GIC phandle
        #expect(readBE32(map, at: 20) == 0) // GIC parent address cell 0
        #expect(readBE32(map, at: 24) == 0) // GIC parent address cell 1
        #expect(readBE32(map, at: 28) == 0) // GIC SPI type
        #expect(readBE32(map, at: 32) == 4) // INTID 36 as SPI offset 4
        #expect(readBE32(map, at: 36) == 4) // IRQ_TYPE_LEVEL_HIGH
    }
}

private func readBE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 |
        UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 |
        UInt32(data[offset + 3])
}

private func fdtProperty(_ data: Data, node targetNode: String, property targetProperty: String) -> Data? {
    let structOffset = Int(readBE32(data, at: 8))
    let stringsOffset = Int(readBE32(data, at: 12))
    let structSize = Int(readBE32(data, at: 36))
    var offset = structOffset
    let end = structOffset + structSize
    var nodeStack: [String] = []

    while offset + 4 <= end {
        let token = readBE32(data, at: offset)
        offset += 4

        switch token {
        case 0x0000_0001: // FDT_BEGIN_NODE
            let start = offset
            while offset < end, data[offset] != 0 {
                offset += 1
            }
            let name = String(data: data[start..<offset], encoding: .utf8) ?? ""
            offset += 1
            offset = align4(offset)
            nodeStack.append(name)

        case 0x0000_0002: // FDT_END_NODE
            _ = nodeStack.popLast()

        case 0x0000_0003: // FDT_PROP
            guard offset + 8 <= end else { return nil }
            let length = Int(readBE32(data, at: offset))
            let nameOffset = Int(readBE32(data, at: offset + 4))
            offset += 8
            guard offset + length <= data.count else { return nil }
            let propertyName = fdtString(data, stringsOffset: stringsOffset, nameOffset: nameOffset)
            let value = Data(data[offset..<offset + length])
            offset = align4(offset + length)
            if nodeStack.last == targetNode, propertyName == targetProperty {
                return value
            }

        case 0x0000_0004: // FDT_NOP
            continue

        case 0x0000_0009: // FDT_END
            return nil

        default:
            return nil
        }
    }

    return nil
}

private func fdtString(_ data: Data, stringsOffset: Int, nameOffset: Int) -> String {
    var offset = stringsOffset + nameOffset
    let start = offset
    while offset < data.count, data[offset] != 0 {
        offset += 1
    }
    return String(data: data[start..<offset], encoding: .utf8) ?? ""
}

private func align4(_ value: Int) -> Int {
    (value + 3) & ~3
}
