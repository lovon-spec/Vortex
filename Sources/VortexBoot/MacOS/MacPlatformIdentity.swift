// MacPlatformIdentity.swift -- Hardware model and machine identity for macOS VMs.
// VortexBoot
//
// macOS guests require a hardware model identifier and a unique per-VM machine
// identifier to complete the boot process and personalize the installation.
// This module generates, persists, and loads these identity blobs.
//
// The actual wire format of these blobs is determined by Apple's Virtualization
// framework internals. For now we generate opaque random data of the correct
// sizes and provide clear extension points for when the real format is
// reverse-engineered.

import Foundation
import VortexCore

// MARK: - Mac Platform Identity

/// Identifies a macOS virtual machine to the guest boot chain.
///
/// Each macOS VM needs two identity components:
/// - **Hardware model data**: Tells the guest which hardware model it is
///   running on. This determines available features (e.g. Neural Engine,
///   Thunderbolt) and governs software update compatibility.
/// - **Machine identifier data**: A unique per-VM blob analogous to a
///   physical Mac's unique serial/ECID. Used for personalization and
///   activation.
///
/// Identities are persisted alongside the VM bundle and must remain stable
/// across VM restarts. Changing the identity may invalidate the macOS
/// installation or activation state.
///
/// ## Persistence
/// ```swift
/// // Generate and save.
/// let identity = MacPlatformIdentity.generate()
/// try identity.save(to: identityFileURL)
///
/// // Load in a subsequent session.
/// let loaded = try MacPlatformIdentity.load(from: identityFileURL)
/// ```
public struct MacPlatformIdentity: Codable, Sendable, Hashable {

    // MARK: - Properties

    /// Opaque hardware model data.
    ///
    /// On real Apple Virtualization.framework, this is typically 4 bytes
    /// identifying the virtual hardware model. The actual encoding is
    /// proprietary.
    public let hardwareModelData: Data

    /// Opaque per-VM machine identifier data.
    ///
    /// On real Apple Virtualization.framework, this is typically 16 bytes.
    /// It must be unique per VM and must remain stable for the VM's lifetime.
    public let machineIdentifierData: Data

    // MARK: - Init

    /// Creates a platform identity from existing data blobs.
    ///
    /// - Parameters:
    ///   - hardwareModelData: Raw hardware model bytes.
    ///   - machineIdentifierData: Raw machine identifier bytes.
    public init(hardwareModelData: Data, machineIdentifierData: Data) {
        self.hardwareModelData = hardwareModelData
        self.machineIdentifierData = machineIdentifierData
    }

    // MARK: - Generation

    /// Expected size of the hardware model data blob.
    ///
    /// Based on observed VZMacHardwareModel serialization. This may need
    /// adjustment once the exact format is determined through research.
    public static let hardwareModelSize = 32

    /// Expected size of the machine identifier data blob.
    ///
    /// Based on observed VZMacMachineIdentifier serialization.
    public static let machineIdentifierSize = 16

    /// Generates a new platform identity with random data.
    ///
    /// The hardware model data is initialized with a plausible header
    /// followed by random bytes. The machine identifier is fully random,
    /// analogous to a UUID.
    ///
    /// - Note: This generates placeholder identity data. Once the actual
    ///   wire format is reverse-engineered, this method should be updated
    ///   to produce valid blobs. See `MacBootChain` for the integration
    ///   point where identity data is consumed.
    ///
    /// - Returns: A newly generated identity.
    public static func generate() -> MacPlatformIdentity {
        let hardwareModel = generateHardwareModelData()
        let machineIdentifier = generateMachineIdentifierData()
        return MacPlatformIdentity(
            hardwareModelData: hardwareModel,
            machineIdentifierData: machineIdentifier
        )
    }

    // MARK: - Persistence

    /// Saves the identity to a file in JSON format.
    ///
    /// The identity is encoded as a JSON object with base64-encoded data
    /// fields for portability and human inspectability.
    ///
    /// - Parameter url: File URL to write the identity to.
    /// - Throws: If the file cannot be written.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Loads a previously saved identity from a file.
    ///
    /// - Parameter url: File URL to read the identity from.
    /// - Returns: The loaded identity.
    /// - Throws: `VortexError.fileNotFound` if the file does not exist,
    ///   or `VortexError.bootFailed` if the file is not valid JSON.
    public static func load(from url: URL) throws -> MacPlatformIdentity {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VortexError.fileNotFound(path: url.path)
        }

        let data = try Data(contentsOf: url)

        do {
            return try JSONDecoder().decode(MacPlatformIdentity.self, from: data)
        } catch {
            throw VortexError.bootFailed(
                reason: "Failed to decode platform identity at \(url.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Validation

    /// Whether this identity has plausible data sizes.
    ///
    /// Returns false if either blob is empty, which would indicate
    /// a corrupted or uninitialized identity file.
    public var isValid: Bool {
        !hardwareModelData.isEmpty && !machineIdentifierData.isEmpty
    }

    // MARK: - Private Helpers

    /// Generates hardware model data.
    ///
    /// The hardware model identifies the virtual platform type. On real
    /// Apple hardware this encodes the board ID, chip ID, and supported
    /// features. Our placeholder uses a fixed magic prefix followed by
    /// random bytes.
    private static func generateHardwareModelData() -> Data {
        var data = Data(count: hardwareModelSize)

        // Write a recognizable magic prefix so we can identify Vortex-generated
        // identity files. Bytes: "VXHW" (Vortex Hardware).
        let magic: [UInt8] = [0x56, 0x58, 0x48, 0x57]
        data.replaceSubrange(0..<4, with: magic)

        // Fill the remainder with random bytes.
        for i in 4..<hardwareModelSize {
            data[i] = UInt8.random(in: 0...255)
        }

        return data
    }

    /// Generates unique machine identifier data.
    ///
    /// This is analogous to a hardware serial number / ECID. It must be
    /// unique per VM instance. We use `UUID` for the core uniqueness and
    /// encode it as raw bytes.
    private static func generateMachineIdentifierData() -> Data {
        var uuid = UUID().uuid
        return Data(bytes: &uuid, count: machineIdentifierSize)
    }
}

// MARK: - CustomStringConvertible

extension MacPlatformIdentity: CustomStringConvertible {
    public var description: String {
        let hwHex = hardwareModelData.prefix(8).map { String(format: "%02x", $0) }.joined()
        let midHex = machineIdentifierData.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "MacPlatformIdentity(hwModel: \(hwHex)..., machineID: \(midHex)...)"
    }
}
