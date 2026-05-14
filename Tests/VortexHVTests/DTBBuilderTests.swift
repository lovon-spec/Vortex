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
}

private func readBE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 |
        UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 |
        UInt32(data[offset + 3])
}
