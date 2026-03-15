import WinRunShared
import XCTest

@testable import WinRunSetup

final class VMProvisionerLauncherTests: XCTestCase {
    private var testDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMProvisionerLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let testDirectory, FileManager.default.fileExists(atPath: testDirectory.path) {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        try await super.tearDown()
    }

    func testStartInstallation_RealLauncherPath_SucceedsWhenHelperLaunches() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let helper = MockInstallerHelper(
            preflightResult: .ready(),
            launchBehavior: { _, _, _, _ in
                InstallerLaunchSession(
                    qemuProcess: Process(),
                    swtpmProcess: nil,
                    cleanup: {}
                )
            }
        )
        let provisioner = VMProvisioner(allowSimulation: false, installerHelper: helper)

        let result = try await provisioner.startInstallation(
            configuration: ProvisioningConfiguration(isoPath: isoPath, diskImagePath: diskPath)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.finalPhase, .complete)
    }

    func testStartInstallation_RealLauncherPath_PreflightFailureMapsToInstallerLaunchError() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let helper = MockInstallerHelper(
            preflightResult: InstallerPreflightResult(
                checks: [],
                blockingIssues: ["Missing qemu-system-aarch64 binary."],
                warnings: []
            ),
            launchBehavior: { _, _, _, _ in
                XCTFail("launchInstaller should not be called when preflight is not launchable")
                return InstallerLaunchSession(
                    qemuProcess: Process(),
                    swtpmProcess: nil,
                    cleanup: {}
                )
            }
        )
        let provisioner = VMProvisioner(allowSimulation: false, installerHelper: helper)

        let result = try await provisioner.startInstallation(
            configuration: ProvisioningConfiguration(isoPath: isoPath, diskImagePath: diskPath)
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .failed)
        guard let error = result.error else {
            return XCTFail("Expected installer launch error")
        }
        if case .installerLaunchFailed(let reason) = error {
            XCTAssertTrue(reason.contains("Missing qemu-system-aarch64"))
        } else {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartInstallation_RealLauncherPath_CancelMapsToCancelledResult() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let helper = MockInstallerHelper(
            preflightResult: .ready(),
            launchBehavior: { _, _, _, _ in
                throw WinRunError.cancelled
            }
        )
        let provisioner = VMProvisioner(allowSimulation: false, installerHelper: helper)

        let result = try await provisioner.startInstallation(
            configuration: ProvisioningConfiguration(isoPath: isoPath, diskImagePath: diskPath)
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .cancelled)
        if case .cancelled? = result.error {
            // expected
        } else {
            XCTFail("Expected cancelled error, got \(String(describing: result.error))")
        }
    }

    private func createTestFile(named name: String, size: Int = 1024) throws -> URL {
        let path = testDirectory.appendingPathComponent(name)
        let data = Data(repeating: 0, count: size)
        try data.write(to: path)
        return path
    }
}

private struct MockInstallerHelper: InstallerLaunchHelping {
    let preflightResult: InstallerPreflightResult
    let launchBehavior: @Sendable (
        ProvisioningConfiguration,
        ProvisioningVMConfiguration,
        URL?,
        @escaping @Sendable (String) -> Void
    ) throws -> InstallerLaunchSession

    func preflight(
        configuration _: ProvisioningConfiguration,
        vmConfiguration _: ProvisioningVMConfiguration,
        resourcesDirectory _: URL?
    ) -> InstallerPreflightResult {
        preflightResult
    }

    func launchInstaller(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        resourcesDirectory: URL?,
        outputHandler: @escaping @Sendable (String) -> Void
    ) throws -> InstallerLaunchSession {
        try launchBehavior(configuration, vmConfiguration, resourcesDirectory, outputHandler)
    }
}

private extension InstallerPreflightResult {
    static func ready() -> InstallerPreflightResult {
        InstallerPreflightResult(
            checks: [],
            blockingIssues: [],
            warnings: []
        )
    }
}
