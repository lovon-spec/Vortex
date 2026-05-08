// NetworkConfigTests.swift -- Tests for network configuration models.
// VortexCoreTests

import Foundation
import Testing
@testable import VortexCore

@Suite("Network configuration")
struct NetworkConfigTests {

    @Test("vmnet shared mode round-trips through JSON")
    func vmnetSharedModeRoundTrips() throws {
        let subnet = try IPv4Subnet(cidr: "192.168.65.3/24")
        let config = NetworkConfiguration(
            interfaces: [
                .vmnetShared(
                    networkID: "lab",
                    ipv4Subnet: subnet,
                    label: "Lab LAN"
                ),
            ]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: data)

        #expect(decoded == config)
        #expect(decoded.interfaces.first?.mode.displayName == "Shared LAN (lab, 192.168.65.0/24)")
    }

    @Test("vmnet shared mode decodes legacy JSON without subnet")
    func vmnetSharedLegacyJSONDecodes() throws {
        let data = Data("""
        {
          "interfaces": [
            {
              "id": "3A0D3B06-9CF3-4EBE-9C05-62E75A987C7B",
              "mode": {
                "type": "vmnetShared",
                "networkID": "lab"
              },
              "macAddress": null,
              "label": "Lab LAN"
            }
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: data)

        guard case .vmnetShared(let vmnet) = decoded.interfaces.first?.mode else {
            Issue.record("Expected vmnet shared mode")
            return
        }
        #expect(vmnet.networkID == "lab")
        #expect(vmnet.ipv4Subnet == nil)
        #expect(decoded.interfaces.first?.mode.displayName == "Shared LAN (lab)")
    }

    @Test("IPv4 subnet canonicalizes and exposes host address")
    func ipv4SubnetCanonicalizes() throws {
        let subnet = try IPv4Subnet(cidr: "192.168.65.45/24")

        #expect(subnet.cidrNotation == "192.168.65.0/24")
        #expect(subnet.subnetMask == "255.255.255.0")
        #expect(subnet.hostAddress == "192.168.65.1")
    }

    @Test("IPv4 subnet rejects public ranges")
    func ipv4SubnetRejectsPublicRanges() {
        #expect(throws: IPv4SubnetError.self) {
            _ = try IPv4Subnet(cidr: "8.8.8.0/24")
        }
    }
}
