// VMConfigCodec.swift — JSON encoding/decoding helpers for VM persistence.
// VortexPersistence

import Foundation
import VortexCore

/// Provides consistently-configured JSON encoders and decoders for VM
/// configuration and snapshot metadata serialization.
///
/// All persistence operations throughout `VortexPersistence` should use
/// these shared instances to ensure consistent date formatting, key
/// encoding, and output formatting.
public enum VMConfigCodec {

    // MARK: - Encoder

    /// A `JSONEncoder` configured for Vortex VM persistence.
    ///
    /// Settings:
    /// - `.prettyPrinted` and `.sortedKeys` for human-readable, diff-friendly output.
    /// - `.iso8601` date strategy for unambiguous timestamps.
    /// - `.withoutEscapingSlashes` for clean path strings.
    ///
    /// - Note: Thread-safe. `JSONEncoder` instances are safe to use from any thread.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// A `JSONDecoder` configured to match `encoder`.
    ///
    /// - Note: Thread-safe. `JSONDecoder` instances are safe to use from any thread.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Convenience

    /// Encodes a `Codable` value to JSON `Data`.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: UTF-8 JSON data.
    /// - Throws: `VortexError.persistenceFailed` if encoding fails.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw VortexError.persistenceFailed(
                reason: "JSON encoding failed: \(error.localizedDescription)"
            )
        }
    }

    /// Decodes a `Codable` value from JSON `Data`.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - data: The JSON data to decode from.
    /// - Returns: The decoded value.
    /// - Throws: `VortexError.persistenceFailed` if decoding fails.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw VortexError.persistenceFailed(
                reason: "JSON decoding failed for \(T.self): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Base64 helpers

    /// Encodes raw `Data` as a base64-encoded string suitable for JSON storage.
    ///
    /// Useful for embedding small binary payloads (machine identifiers, EFI
    /// variable snapshots) inside JSON configuration files.
    ///
    /// - Parameter data: The binary data to encode.
    /// - Returns: A base64-encoded string.
    public static func base64Encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    /// Decodes a base64-encoded string back to `Data`.
    ///
    /// - Parameter string: The base64-encoded string.
    /// - Returns: The decoded binary data.
    /// - Throws: `VortexError.persistenceFailed` if the string is not valid base64.
    public static func base64Decode(_ string: String) throws -> Data {
        guard let data = Data(base64Encoded: string) else {
            throw VortexError.persistenceFailed(
                reason: "Invalid base64 string."
            )
        }
        return data
    }
}
