// VmnetNetworkRegistry.swift -- Shared vmnet-backed network attachments.
// VortexVZ

import Foundation
import Virtualization
import VortexCore
import vmnet

@MainActor
final class VmnetNetworkRegistry {
    static let shared = VmnetNetworkRegistry()

    private var networks: [VmnetNetworkKey: vmnet_network_ref] = [:]

    private init() {}

    func attachment(
        kind: VmnetNetworkKind,
        networkID: String
    ) throws -> VZNetworkDeviceAttachment {
        guard #available(macOS 26.0, *) else {
            throw VortexError.unsupported(
                feature: "vmnet network attachment",
                reason: "VZVmnetNetworkDeviceAttachment requires macOS 26.0 or newer."
            )
        }

        let network = try network(
            kind: kind,
            networkID: normalizedNetworkID(networkID)
        )
        return VZVmnetNetworkDeviceAttachment(network: network)
    }

    @available(macOS 26.0, *)
    private func network(
        kind: VmnetNetworkKind,
        networkID: String
    ) throws -> vmnet_network_ref {
        let key = VmnetNetworkKey(kind: kind, networkID: networkID)
        if let existing = networks[key] {
            return existing
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

        guard let network = vmnet_network_create(configuration, &status) else {
            throw makeVmnetError(
                action: "create \(kind.displayName) network",
                status: status
            )
        }

        networks[key] = network
        return network
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
                + "vmnet networks require macOS 26.0+ and the com.apple.vm.networking entitlement."
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
