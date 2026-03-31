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
}

// MARK: - Network mode

/// The type of virtual network attachment.
public enum NetworkMode: Codable, Sendable, Hashable {
    /// NAT mode: the guest shares the host's network connection.
    /// The guest can reach external networks; inbound connections require port forwarding.
    case nat

    /// Bridged mode: the guest appears as a peer on the host's physical network.
    /// Requires specifying which host interface to bridge to.
    case bridged(hostInterface: String)

    /// Host-only mode: the guest can communicate only with the host.
    /// No external network access.
    case hostOnly
}

// MARK: - NetworkMode CodingKeys

extension NetworkMode {
    private enum CodingKeys: String, CodingKey {
        case type
        case hostInterface
    }

    private enum ModeType: String, Codable {
        case nat
        case bridged
        case hostOnly
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
        }
    }
}
