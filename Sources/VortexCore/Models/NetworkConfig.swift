// NetworkConfig.swift — Network interface configuration.
// VortexCore

import Foundation

/// Top-level network configuration for a VM.
public struct NetworkConfiguration: Codable, Sendable, Hashable {
    /// Network interfaces attached to the VM, in order.
    public var interfaces: [NetworkInterfaceConfig]

    public init(interfaces: [NetworkInterfaceConfig] = []) {
        self.interfaces = interfaces
    }

    /// A configuration with a single NAT interface (the most common setup).
    public static let singleNAT = NetworkConfiguration(
        interfaces: [.nat()]
    )

    /// No network connectivity.
    public static let none = NetworkConfiguration(interfaces: [])
}

/// Configuration for a single virtual network interface.
public struct NetworkInterfaceConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID

    /// The type of network attachment.
    public var mode: NetworkMode

    /// Optional MAC address override. When `nil`, a random MAC is generated at VM creation.
    /// Format: `"AA:BB:CC:DD:EE:FF"`.
    public var macAddress: String?

    /// Optional human-readable label (e.g. "Primary", "Management").
    public var label: String?

    public init(
        id: UUID = UUID(),
        mode: NetworkMode = .nat,
        macAddress: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.mode = mode
        self.macAddress = macAddress
        self.label = label
    }

    // MARK: - Factory

    /// Create a NAT interface (guest can reach the internet; host routes traffic).
    public static func nat(label: String? = nil) -> NetworkInterfaceConfig {
        NetworkInterfaceConfig(mode: .nat, label: label ?? "NAT")
    }

    /// Create a bridged interface attached to a specific host network interface.
    public static func bridged(hostInterface: String, label: String? = nil) -> NetworkInterfaceConfig {
        NetworkInterfaceConfig(mode: .bridged(hostInterface: hostInterface), label: label ?? "Bridged")
    }

    /// Create a host-only interface for isolated host-guest communication.
    public static func hostOnly(label: String? = nil) -> NetworkInterfaceConfig {
        NetworkInterfaceConfig(mode: .hostOnly, label: label ?? "Host Only")
    }

    /// Create a shared vmnet LAN interface for VM-to-VM communication.
    public static func vmnetShared(
        networkID: String = NetworkMode.defaultVmnetNetworkID,
        ipv4Subnet: IPv4Subnet? = nil,
        label: String? = nil
    ) -> NetworkInterfaceConfig {
        NetworkInterfaceConfig(
            mode: .vmnetShared(
                VmnetSharedNetworkConfig(
                    networkID: networkID,
                    ipv4Subnet: ipv4Subnet
                )
            ),
            label: label ?? "Shared LAN"
        )
    }
}

// MARK: - IPv4 subnet

public enum IPv4SubnetError: LocalizedError, Equatable {
    case invalidCIDR(String)
    case invalidAddress(String)
    case invalidPrefixLength(Int)
    case notPrivate(String)
    case invalidMask(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCIDR(let value):
            return "\"\(value)\" is not a valid IPv4 CIDR subnet."
        case .invalidAddress(let value):
            return "\"\(value)\" is not a valid IPv4 address."
        case .invalidPrefixLength(let value):
            return "IPv4 prefix length \(value) is not valid for vmnet. Use /8 through /30."
        case .notPrivate(let value):
            return "\(value) is not fully inside an RFC 1918 private IPv4 range."
        case .invalidMask(let value):
            return "\(value) is not a contiguous IPv4 subnet mask."
        }
    }
}

public struct IPv4Subnet: Codable, Sendable, Hashable, CustomStringConvertible {
    public var networkAddress: String
    public var prefixLength: Int

    public init(cidr: String) throws {
        let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]) else {
            throw IPv4SubnetError.invalidCIDR(cidr)
        }

        let address = try Self.parseIPv4(String(parts[0]))
        try Self.validate(prefixLength: prefix)
        let mask = Self.maskValue(prefixLength: prefix)
        let network = address & mask
        let broadcast = network | ~mask
        guard Self.isPrivate(network) && Self.isPrivate(broadcast) else {
            throw IPv4SubnetError.notPrivate("\(Self.string(from: network))/\(prefix)")
        }

        self.networkAddress = Self.string(from: network)
        self.prefixLength = prefix
    }

    public init(networkAddressValue: UInt32, subnetMaskValue: UInt32) throws {
        let prefix = try Self.prefixLength(fromMask: subnetMaskValue)
        let network = networkAddressValue & subnetMaskValue
        try self.init(cidr: "\(Self.string(from: network))/\(prefix)")
    }

    public var cidrNotation: String {
        "\(networkAddress)/\(prefixLength)"
    }

    public var description: String {
        cidrNotation
    }

    public var networkAddressValue: UInt32 {
        // The initializer guarantees this cannot fail.
        (try? Self.parseIPv4(networkAddress)) ?? 0
    }

    public var subnetMaskValue: UInt32 {
        Self.maskValue(prefixLength: prefixLength)
    }

    public var subnetMask: String {
        Self.string(from: subnetMaskValue)
    }

    public var hostAddress: String {
        Self.string(from: networkAddressValue + 1)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let cidr = try container.decode(String.self)
        do {
            self = try Self(cidr: cidr)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cidrNotation)
    }

    private static func validate(prefixLength: Int) throws {
        guard (8...30).contains(prefixLength) else {
            throw IPv4SubnetError.invalidPrefixLength(prefixLength)
        }
    }

    private static func parseIPv4(_ value: String) throws -> UInt32 {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else {
            throw IPv4SubnetError.invalidAddress(value)
        }

        var result: UInt32 = 0
        for piece in pieces {
            guard let byte = UInt8(piece) else {
                throw IPv4SubnetError.invalidAddress(value)
            }
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func maskValue(prefixLength: Int) -> UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
    }

    private static func prefixLength(fromMask mask: UInt32) throws -> Int {
        var sawZero = false
        var prefix = 0

        for bit in (0..<32).reversed() {
            let isSet = ((mask >> UInt32(bit)) & 1) == 1
            if isSet {
                if sawZero {
                    throw IPv4SubnetError.invalidMask(Self.string(from: mask))
                }
                prefix += 1
            } else {
                sawZero = true
            }
        }

        try validate(prefixLength: prefix)
        return prefix
    }

    private static func isPrivate(_ value: UInt32) -> Bool {
        let first = (value >> 24) & 0xff
        let second = (value >> 16) & 0xff

        if first == 10 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        return false
    }

    private static func string(from value: UInt32) -> String {
        let first = (value >> 24) & 0xff
        let second = (value >> 16) & 0xff
        let third = (value >> 8) & 0xff
        let fourth = value & 0xff
        return "\(first).\(second).\(third).\(fourth)"
    }
}

// MARK: - vmnet shared LAN configuration

public struct VmnetSharedNetworkConfig: Codable, Sendable, Hashable {
    public var networkID: String
    public var ipv4Subnet: IPv4Subnet?

    public init(
        networkID: String = NetworkMode.defaultVmnetNetworkID,
        ipv4Subnet: IPv4Subnet? = nil
    ) {
        self.networkID = networkID
        self.ipv4Subnet = ipv4Subnet
    }

    public var normalizedNetworkID: String {
        let trimmed = networkID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NetworkMode.defaultVmnetNetworkID : trimmed
    }

    public var displayName: String {
        if let ipv4Subnet {
            return "\(normalizedNetworkID), \(ipv4Subnet.cidrNotation)"
        }
        return normalizedNetworkID
    }
}

// MARK: - vmnet runtime status

public struct VmnetNetworkStatus: Sendable, Hashable, Identifiable {
    public var kind: String
    public var networkID: String
    public var configuredIPv4Subnet: IPv4Subnet?
    public var activeIPv4Subnet: IPv4Subnet?

    public init(
        kind: String,
        networkID: String,
        configuredIPv4Subnet: IPv4Subnet?,
        activeIPv4Subnet: IPv4Subnet?
    ) {
        self.kind = kind
        self.networkID = networkID
        self.configuredIPv4Subnet = configuredIPv4Subnet
        self.activeIPv4Subnet = activeIPv4Subnet
    }

    public var id: String {
        "\(kind):\(networkID)"
    }

    public var hostIPv4Address: String? {
        activeIPv4Subnet?.hostAddress
    }
}

// MARK: - Network mode

/// The type of virtual network attachment.
public enum NetworkMode: Codable, Sendable, Hashable {
    public static let defaultVmnetNetworkID = "default"

    /// NAT mode: the guest shares the host's network connection.
    /// The guest can reach external networks; inbound connections require port forwarding.
    case nat

    /// Bridged mode: the guest appears as a peer on the host's physical network.
    /// Requires specifying which host interface to bridge to.
    case bridged(hostInterface: String)

    /// Host-only mode: the guest can communicate only with the host.
    /// No external network access.
    case hostOnly

    /// vmnet shared mode: guests on the same in-process vmnet network share a private LAN.
    /// This uses Virtualization.framework's VZVmnetNetworkDeviceAttachment on macOS 26+.
    case vmnetShared(VmnetSharedNetworkConfig)
}

// MARK: - NetworkMode CodingKeys

extension NetworkMode {
    private enum CodingKeys: String, CodingKey {
        case type
        case hostInterface
        case networkID
        case ipv4Subnet
    }

    private enum ModeType: String, Codable {
        case nat
        case bridged
        case hostOnly
        case vmnetShared
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ModeType.self, forKey: .type)
        switch type {
        case .nat:
            self = .nat
        case .bridged:
            let hostInterface = try container.decode(String.self, forKey: .hostInterface)
            self = .bridged(hostInterface: hostInterface)
        case .hostOnly:
            self = .hostOnly
        case .vmnetShared:
            let networkID = try container.decodeIfPresent(String.self, forKey: .networkID)
                ?? Self.defaultVmnetNetworkID
            let ipv4Subnet = try container.decodeIfPresent(IPv4Subnet.self, forKey: .ipv4Subnet)
            self = .vmnetShared(
                VmnetSharedNetworkConfig(
                    networkID: networkID,
                    ipv4Subnet: ipv4Subnet
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nat:
            try container.encode(ModeType.nat, forKey: .type)
        case .bridged(let hostInterface):
            try container.encode(ModeType.bridged, forKey: .type)
            try container.encode(hostInterface, forKey: .hostInterface)
        case .hostOnly:
            try container.encode(ModeType.hostOnly, forKey: .type)
        case .vmnetShared(let vmnet):
            try container.encode(ModeType.vmnetShared, forKey: .type)
            try container.encode(vmnet.networkID, forKey: .networkID)
            try container.encodeIfPresent(vmnet.ipv4Subnet, forKey: .ipv4Subnet)
        }
    }
}

extension NetworkMode {
    /// Short display label for UI summaries.
    public var displayName: String {
        switch self {
        case .nat:
            return "NAT"
        case .bridged(let hostInterface):
            return "Bridged (\(hostInterface))"
        case .hostOnly:
            return "Host Only"
        case .vmnetShared(let vmnet):
            return "Shared LAN (\(vmnet.displayName))"
        }
    }
}
