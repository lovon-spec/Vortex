// VmnetNetworkRegistry.swift -- Shared vmnet-backed network attachments.
// VortexVZ

import Foundation
import Virtualization
import VortexCore
import vmnet
import Darwin

@MainActor
public final class VmnetNetworkRegistry {
    public static let shared = VmnetNetworkRegistry()

    private var networks: [VmnetNetworkKey: VmnetNetworkEntry] = [:]

    private init() {}

    func attachment(
        kind: VmnetNetworkKind,
        networkID: String,
        ipv4Subnet: IPv4Subnet? = nil
    ) throws -> VZNetworkDeviceAttachment {
        guard #available(macOS 26.0, *) else {
            throw VortexError.unsupported(
                feature: "vmnet network attachment",
                reason: "VZVmnetNetworkDeviceAttachment requires macOS 26.0 or newer."
            )
        }

        let network = try network(
            kind: kind,
            networkID: normalizedNetworkID(networkID),
            ipv4Subnet: ipv4Subnet
        )
        return VZVmnetNetworkDeviceAttachment(network: network)
    }

    public func releaseNetworks(for interfaces: [NetworkInterfaceConfig]) {
        for iface in interfaces {
            let key: VmnetNetworkKey?
            switch iface.mode {
            case .hostOnly:
                key = VmnetNetworkKey(
                    kind: .hostOnly,
                    networkID: NetworkMode.defaultVmnetNetworkID
                )
            case .vmnetShared(let vmnet):
                key = VmnetNetworkKey(
                    kind: .shared,
                    networkID: vmnet.normalizedNetworkID
                )
            case .nat, .bridged:
                key = nil
            }

            guard let key, var entry = networks[key] else { continue }
            if entry.referenceCount <= 1 {
                release(entry.network)
                networks.removeValue(forKey: key)
            } else {
                entry.referenceCount -= 1
                networks[key] = entry
            }
        }
    }

    public func statuses(for interfaces: [NetworkInterfaceConfig]) -> [VmnetNetworkStatus] {
        interfaces.compactMap { iface in
            switch iface.mode {
            case .hostOnly:
                return status(
                    kind: .hostOnly,
                    networkID: NetworkMode.defaultVmnetNetworkID
                )
            case .vmnetShared(let vmnet):
                return status(
                    kind: .shared,
                    networkID: vmnet.normalizedNetworkID
                )
            case .nat, .bridged:
                return nil
            }
        }
    }

    func status(kind: VmnetNetworkKind, networkID: String) -> VmnetNetworkStatus? {
        let key = VmnetNetworkKey(
            kind: kind,
            networkID: normalizedNetworkID(networkID)
        )
        return networks[key]?.status
    }

    @available(macOS 26.0, *)
    private func network(
        kind: VmnetNetworkKind,
        networkID: String,
        ipv4Subnet: IPv4Subnet?
    ) throws -> vmnet_network_ref {
        let key = VmnetNetworkKey(kind: kind, networkID: networkID)
        if var existing = networks[key] {
            if existing.status.configuredIPv4Subnet != ipv4Subnet {
                throw VortexError.networkConfigurationFailed(
                    reason: "\(kind.displayName) network '\(networkID)' is already active with "
                        + "\(existing.status.configuredIPv4Subnet?.cidrNotation ?? "automatic IPv4 subnet selection"); "
                        + "it cannot be reused with \(ipv4Subnet?.cidrNotation ?? "automatic IPv4 subnet selection") until the active VMs using it stop."
                )
            }
            existing.referenceCount += 1
            networks[key] = existing
            return existing.network
        }

        var status = vmnet_return_t.VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(
            kind.operatingMode,
            &status
        ) else {
            throw makeVmnetError(
                action: "create \(kind.displayName) network configuration",
                status: status
            )
        }
        defer { release(configuration) }

        if let ipv4Subnet {
            var subnetAddress = in_addr(s_addr: ipv4Subnet.networkAddressValue.bigEndian)
            var subnetMask = in_addr(s_addr: ipv4Subnet.subnetMaskValue.bigEndian)
            let subnetStatus = vmnet_network_configuration_set_ipv4_subnet(
                configuration,
                &subnetAddress,
                &subnetMask
            )
            guard subnetStatus == .VMNET_SUCCESS else {
                throw makeVmnetError(
                    action: "configure \(kind.displayName) IPv4 subnet \(ipv4Subnet.cidrNotation)",
                    status: subnetStatus
                )
            }
        }

        guard let network = vmnet_network_create(configuration, &status) else {
            throw makeVmnetError(
                action: "create \(kind.displayName) network",
                status: status
            )
        }

        let activeIPv4Subnet = queryIPv4Subnet(network)
        networks[key] = VmnetNetworkEntry(
            network: network,
            status: VmnetNetworkStatus(
                kind: kind.displayName,
                networkID: networkID,
                configuredIPv4Subnet: ipv4Subnet,
                activeIPv4Subnet: activeIPv4Subnet
            ),
            referenceCount: 1
        )
        return network
    }

    @available(macOS 26.0, *)
    private func queryIPv4Subnet(_ network: vmnet_network_ref) -> IPv4Subnet? {
        var subnetAddress = in_addr(s_addr: 0)
        var subnetMask = in_addr(s_addr: 0)
        vmnet_network_get_ipv4_subnet(network, &subnetAddress, &subnetMask)
        return try? IPv4Subnet(
            networkAddressValue: UInt32(bigEndian: subnetAddress.s_addr),
            subnetMaskValue: UInt32(bigEndian: subnetMask.s_addr)
        )
    }

    private func normalizedNetworkID(_ networkID: String) -> String {
        let trimmed = networkID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NetworkMode.defaultVmnetNetworkID : trimmed
    }

    private func makeVmnetError(
        action: String,
        status: vmnet_return_t
    ) -> VortexError {
        VortexError.networkConfigurationFailed(
            reason: "Failed to \(action): \(statusDescription(status)). "
                + "vmnet networks require macOS 26.0+ and a launchable Virtualization.framework entitlement set."
        )
    }

    private func statusDescription(_ status: vmnet_return_t) -> String {
        switch status {
        case .VMNET_SUCCESS:
            return "success"
        case .VMNET_FAILURE:
            return "general failure"
        case .VMNET_MEM_FAILURE:
            return "memory allocation failure"
        case .VMNET_INVALID_ARGUMENT:
            return "invalid argument"
        case .VMNET_SETUP_INCOMPLETE:
            return "interface setup incomplete"
        case .VMNET_INVALID_ACCESS:
            return "permission denied"
        case .VMNET_PACKET_TOO_BIG:
            return "packet too large"
        case .VMNET_BUFFER_EXHAUSTED:
            return "buffer exhausted"
        case .VMNET_TOO_MANY_PACKETS:
            return "too many packets"
        case .VMNET_SHARING_SERVICE_BUSY:
            return "sharing service busy"
        case .VMNET_NOT_AUTHORIZED:
            return "not authorized"
        default:
            return "vmnet status \(status.rawValue)"
        }
    }

    private func release(_ pointer: OpaquePointer) {
        Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(pointer)).release()
    }
}

enum VmnetNetworkKind: Hashable {
    case shared
    case hostOnly

    @available(macOS 26.0, *)
    var operatingMode: vmnet_mode_t {
        switch self {
        case .shared:
            return operating_modes_t.VMNET_SHARED_MODE
        case .hostOnly:
            return operating_modes_t.VMNET_HOST_MODE
        }
    }

    var displayName: String {
        switch self {
        case .shared:
            return "shared vmnet"
        case .hostOnly:
            return "host-only vmnet"
        }
    }
}

private struct VmnetNetworkKey: Hashable {
    var kind: VmnetNetworkKind
    var networkID: String
}

private struct VmnetNetworkEntry {
    var network: vmnet_network_ref
    var status: VmnetNetworkStatus
    var referenceCount: Int
}
