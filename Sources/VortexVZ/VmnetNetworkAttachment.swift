// VmnetNetworkAttachment.swift -- VZ attachment wrapper for shared vmnet networks.
// VortexVZ

import Virtualization
import VortexCore
import VortexNetworking

extension VmnetNetworkRegistry {
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
            networkID: networkID,
            ipv4Subnet: ipv4Subnet
        )
        return VZVmnetNetworkDeviceAttachment(network: network)
    }
}
