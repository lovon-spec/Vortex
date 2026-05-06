// NetworkConfigTests.swift -- Tests for network configuration models.
// VortexCoreTests

import Foundation
import Testing
@testable import VortexCore

@Suite("Network configuration")
struct NetworkConfigTests {

    @Test("vmnet shared mode round-trips through JSON")
    func vmnetSharedModeRoundTrips() throws {
        let config = NetworkConfiguration(
            interfaces: [
                .vmnetShared(networkID: "lab", label: "Lab LAN"),
            ]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: data)

        #expect(decoded == config)
        #expect(decoded.interfaces.first?.mode.displayName == "Shared LAN (lab)")
    }
}
