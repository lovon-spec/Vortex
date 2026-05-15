// QEMUNBDServerTests.swift -- Tests for managed qcow2 helper process arguments.
// VortexDevicesTests

#if canImport(XCTest)
import XCTest
@testable import VortexDevices

final class QEMUNBDServerTests: XCTestCase {
    func testLocalQEMUNBDArgumentsAreAppScoped() {
        let args = QEMUNBDServer.qemuNBDArguments(
            format: "qcow2",
            port: 32123,
            exportName: "vortex",
            readOnly: false,
            imagePath: "/tmp/disk.qcow2"
        )

        XCTAssertFalse(args.contains("-t"))
        XCTAssertFalse(args.contains("--persistent"))
        XCTAssertTrue(args.contains("--bind=127.0.0.1"))
        XCTAssertEqual(args.suffix(1), ["/tmp/disk.qcow2"])
    }

    func testRemoteQEMUNBDArgumentsAreAppScoped() {
        let args = SSHQEMUNBDTunnel.qemuNBDArguments(
            remotePort: 45678,
            exportName: "vortex",
            readOnly: true,
            imagePath: "/Users/user/VMs/Linux Disk.qcow2"
        )

        XCTAssertFalse(args.contains("-t"))
        XCTAssertFalse(args.contains("--persistent"))
        XCTAssertTrue(args.contains("--bind=127.0.0.1"))
        XCTAssertTrue(args.contains("-r"))
        XCTAssertEqual(args.suffix(1), ["/Users/user/VMs/Linux Disk.qcow2"])
    }
}
#endif
