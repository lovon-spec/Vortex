// HardwareProfileTests.swift -- Tests for HardwareProfile host limit helpers.
// VortexCoreTests

import Testing
@testable import VortexCore

@Suite("HardwareProfile")
struct HardwareProfileTests {

    @Test("GUI memory helpers use whole-GiB bounds")
    func guiMemoryHelpersUseWholeGiBBounds() {
        #expect(HardwareProfile.bytesPerGiB == 1024 * 1024 * 1024)
        #expect(HardwareProfile.minimumMemoryGiB == 1)
        #expect(HardwareProfile.maximumMemoryGiB >= HardwareProfile.minimumMemoryGiB)
    }

    @Test("GiB initializer uses shared GiB byte constant")
    func gibInitializerUsesSharedConstant() {
        let profile = HardwareProfile(cpuCoreCount: 4, memoryGiB: 12)
        #expect(profile.memorySize == 12 * HardwareProfile.bytesPerGiB)
    }
}
