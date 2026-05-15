// VmnetNetworkRegistry.swift -- Shared vmnet-backed network reservations.
// VortexNetworking

import Darwin
import Foundation
import VortexCore
import vmnet

public final class VmnetNetworkRegistry: @unchecked Sendable {
    public static let shared = VmnetNetworkRegistry()

    private let lock = NSLock()
    private var networks: [VmnetNetworkKey: VmnetNetworkEntry] = [:]

    private init() {}

    @available(macOS 26.0, *)
    public func network(
        kind: VmnetNetworkKind,
        networkID: String,
        ipv4Subnet: IPv4Subnet? = nil
    ) throws -> vmnet_network_ref {
        let normalizedID = normalizedNetworkID(networkID)
        let key = VmnetNetworkKey(kind: kind, networkID: normalizedID)

        lock.lock()
        defer { lock.unlock() }

        if var existing = networks[key] {
            if existing.status.configuredIPv4Subnet != ipv4Subnet {
                throw VortexError.networkConfigurationFailed(
                    reason: "\(kind.displayName) network '\(normalizedID)' is already active with "
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
            let subnetDescription = ipv4Subnet.map { " with IPv4 subnet \($0.cidrNotation)" } ?? ""
            let customSubnetHint = ipv4Subnet == nil
                ? nil
                : " Custom IPv4 subnet reservation was rejected by macOS; leave IPv4 Subnet blank to use automatic vmnet subnet selection."
            throw makeVmnetError(
                action: "create \(kind.displayName) network\(subnetDescription)",
                status: status,
                hint: customSubnetHint
            )
        }

        let activeIPv4Subnet = queryIPv4Subnet(network)
        networks[key] = VmnetNetworkEntry(
            network: network,
            status: VmnetNetworkStatus(
                kind: kind.displayName,
                networkID: normalizedID,
                configuredIPv4Subnet: ipv4Subnet,
                activeIPv4Subnet: activeIPv4Subnet
            ),
            referenceCount: 1
        )
        return network
    }

    public func releaseNetwork(kind: VmnetNetworkKind, networkID: String) {
        let key = VmnetNetworkKey(
            kind: kind,
            networkID: normalizedNetworkID(networkID)
        )

        lock.lock()
        guard var entry = networks[key] else {
            lock.unlock()
            return
        }
        if entry.referenceCount <= 1 {
            networks.removeValue(forKey: key)
            lock.unlock()
            release(entry.network)
        } else {
            entry.referenceCount -= 1
            networks[key] = entry
            lock.unlock()
        }
    }

    public func releaseNetworks(for interfaces: [NetworkInterfaceConfig]) {
        for iface in interfaces {
            switch iface.mode {
            case .hostOnly:
                releaseNetwork(
                    kind: .hostOnly,
                    networkID: NetworkMode.defaultVmnetNetworkID
                )
            case .vmnetShared(let vmnet):
                releaseNetwork(
                    kind: .shared,
                    networkID: vmnet.normalizedNetworkID
                )
            case .nat, .bridged:
                break
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

    public func status(kind: VmnetNetworkKind, networkID: String) -> VmnetNetworkStatus? {
        let key = VmnetNetworkKey(
            kind: kind,
            networkID: normalizedNetworkID(networkID)
        )
        lock.lock()
        defer { lock.unlock() }
        return networks[key]?.status
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
        status: vmnet_return_t,
        hint: String? = nil
    ) -> VortexError {
        let hintText = hint.map { " \($0)" } ?? ""
        return VortexError.networkConfigurationFailed(
            reason: "Failed to \(action): \(statusDescription(status)). "
                + "vmnet networks require macOS 26.0+ and a launchable Virtualization.framework entitlement set."
                + hintText
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

public enum VmnetNetworkKind: Hashable, Sendable {
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

    public var displayName: String {
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
