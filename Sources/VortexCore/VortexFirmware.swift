// VortexFirmware.swift -- Bundled firmware discovery and verification.
// VortexCore

import CryptoKit
import Foundation

public enum VortexFirmware {
    public static let aarch64UEFIDirectoryName = "Firmware"
    public static let aarch64UEFIFileName = "edk2-aarch64-code.fd"
    public static let aarch64UEFIReference = "vortex-bundled://Firmware/edk2-aarch64-code.fd"
    public static let aarch64UEFIExpectedSizeBytes: UInt64 = 67_108_864
    public static let aarch64UEFIExpectedSHA256 =
        "6748b7f9ca864e47c565cc2d5fbc2a3133a3e08b56eeab52ff55fe0cd642a16e"

    public static func bundledAArch64UEFIURL(bundle: Bundle = .main) -> URL? {
        candidateBundledFirmwareURLs(bundle: bundle).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func validatedBundledAArch64UEFIPath(bundle: Bundle = .main) throws -> String? {
        guard let url = bundledAArch64UEFIURL(bundle: bundle) else {
            return nil
        }
        try validateBundledAArch64UEFI(at: url)
        return url.path
    }

    public static func resolvedAArch64UEFIPath(_ pathOrReference: String, bundle: Bundle = .main) throws -> String {
        if isBundledAArch64UEFIReference(pathOrReference) {
            guard let bundled = try validatedBundledAArch64UEFIPath(bundle: bundle) else {
                throw VortexError.fileNotFound(path: aarch64UEFIReference)
            }
            return bundled
        }

        if isBundledAArch64UEFIPath(pathOrReference, bundle: bundle) {
            try validateBundledAArch64UEFI(at: URL(fileURLWithPath: pathOrReference))
        }
        return pathOrReference
    }

    public static func validateBundledAArch64UEFI(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values.fileSize ?? -1)
        guard size == aarch64UEFIExpectedSizeBytes else {
            throw VortexError.bootFailed(
                reason: "Bundled AArch64 UEFI firmware size mismatch: expected \(aarch64UEFIExpectedSizeBytes), got \(size)."
            )
        }

        let digest = try sha256Hex(for: url)
        guard digest == aarch64UEFIExpectedSHA256 else {
            throw VortexError.bootFailed(
                reason: "Bundled AArch64 UEFI firmware hash mismatch: expected \(aarch64UEFIExpectedSHA256), got \(digest)."
            )
        }
    }

    public static func isBundledAArch64UEFIPath(_ path: String, bundle: Bundle = .main) -> Bool {
        guard !isBundledAArch64UEFIReference(path) else { return true }
        guard !path.hasPrefix("ssh://") else { return false }
        let normalized = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return candidateBundledFirmwareURLs(bundle: bundle).contains { candidate in
            candidate.standardizedFileURL.resolvingSymlinksInPath().path == normalized
        }
    }

    public static func isBundledFirmwarePath(_ path: String, bundle: Bundle = .main) -> Bool {
        isBundledAArch64UEFIPath(path, bundle: bundle)
    }

    public static func isBundledAArch64UEFIReference(_ path: String) -> Bool {
        path == aarch64UEFIReference
    }

    public static func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func candidateBundledFirmwareURLs(bundle: Bundle) -> [URL] {
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent(aarch64UEFIDirectoryName, isDirectory: true)
                    .appendingPathComponent(aarch64UEFIFileName)
            )
        }
        candidates.append(
            bundle.bundleURL
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .appendingPathComponent(aarch64UEFIDirectoryName, isDirectory: true)
                .appendingPathComponent(aarch64UEFIFileName)
        )
        return candidates
    }
}
