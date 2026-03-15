import XCTest
@testable import WinRunVirtualMachine
@testable import WinRunShared

final class QEMURuntimeProcessManagerTests: XCTestCase {
    func testBuildArgumentsIncludesSpiceAndTpm() {
        let config = VMConfiguration(
            resources: VMResources(cpuCount: 4, memorySizeGB: 8),
            disk: VMDiskConfiguration(imagePath: URL(fileURLWithPath: "/tmp/windows.img"), sizeGB: 64),
            network: VMNetworkConfiguration(mode: .nat, macAddress: "52:54:00:AA:BB:CC")
        )

        let args = QEMURuntimeProcessManager.buildArguments(
            configuration: config,
            firmwareCode: URL(fileURLWithPath: "/tmp/edk2-aarch64-code.fd"),
            nvram: URL(fileURLWithPath: "/tmp/windows.qemu-nvram"),
            tpmSocketPath: URL(fileURLWithPath: "/tmp/swtpm-sock"),
            spicePort: 5930
        )

        XCTAssertTrue(args.contains("-spice"))
        XCTAssertTrue(args.contains("addr=127.0.0.1,port=5930,disable-ticketing=on"))
        XCTAssertTrue(args.contains("-tpmdev"))
        XCTAssertTrue(args.contains("emulator,id=tpm0,chardev=chrtpm"))
        XCTAssertTrue(args.contains("-accel"))
        XCTAssertTrue(args.contains("hvf"))
    }
}
