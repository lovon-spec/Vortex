// VortexFirmwareTests.swift -- Tests for bundled firmware helpers.
// VortexCoreTests

import Foundation
import Testing
@testable import VortexCore

@Suite("VortexFirmware")
struct VortexFirmwareTests {

    @Test("SHA-256 helper returns stable hex")
    func sha256HexReturnsStableHex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexFirmwareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("sample.bin")
        try Data("vortex".utf8).write(to: file)

        #expect(try VortexFirmware.sha256Hex(for: file) == "a5c032f4faf0c5b1a73cfd99b4d481311ada25cee1cf24fe367ef975796a1ced")
    }

    @Test("Bundled firmware reference is recognized")
    func bundledFirmwareReferenceIsRecognized() {
        #expect(VortexFirmware.isBundledFirmwarePath(VortexFirmware.aarch64UEFIReference))
    }

    @Test("Explicit custom firmware path resolves unchanged")
    func explicitCustomFirmwarePathResolvesUnchanged() throws {
        let path = "/tmp/custom-edk2-aarch64-code.fd"

        #expect(try VortexFirmware.resolvedAArch64UEFIPath(path) == path)
    }

    @Test("Invalid bundled firmware is rejected")
    func invalidBundledFirmwareIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VortexFirmwareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent(VortexFirmware.aarch64UEFIFileName)
        try Data("not firmware".utf8).write(to: file)

        #expect(throws: VortexError.self) {
            try VortexFirmware.validateBundledAArch64UEFI(at: file)
        }
    }
}
