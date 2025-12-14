import WinRunShared
import XCTest

@testable import WinRunSetup

final class InstallationLifecycleTests: XCTestCase {
    // MARK: - Properties

    private var testDirectory: URL!
    private var provisioner: VMProvisioner!

    // MARK: - Setup/Teardown

    override func setUp() async throws {
        try await super.setUp()

        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent(
            "InstallationLifecycleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )

        provisioner = VMProvisioner()
    }

    override func tearDown() async throws {
        if let testDirectory = testDirectory,
            FileManager.default.fileExists(atPath: testDirectory.path)
        {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        provisioner = nil

        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTestFile(named name: String, size: Int = 1024) throws -> URL {
        let path = testDirectory.appendingPathComponent(name)
        let data = Data(repeating: 0, count: size)
        try data.write(to: path)
        return path
    }

    // MARK: - Installation Phase Tests

    func testInstallationPhase_AllCasesHaveDisplayName() {
        for phase in InstallationPhase.allCases {
            XCTAssertFalse(phase.displayName.isEmpty, "Phase \(phase) should have display name")
        }
    }

    func testInstallationPhase_TerminalStates() {
        XCTAssertTrue(InstallationPhase.complete.isTerminal)
        XCTAssertTrue(InstallationPhase.failed.isTerminal)
        XCTAssertTrue(InstallationPhase.cancelled.isTerminal)

        XCTAssertFalse(InstallationPhase.preparing.isTerminal)
        XCTAssertFalse(InstallationPhase.booting.isTerminal)
        XCTAssertFalse(InstallationPhase.copyingFiles.isTerminal)
        XCTAssertFalse(InstallationPhase.installingFeatures.isTerminal)
        XCTAssertFalse(InstallationPhase.firstBoot.isTerminal)
        XCTAssertFalse(InstallationPhase.postInstall.isTerminal)
    }

    // MARK: - Installation Progress Tests

    func testInstallationProgress_ClampsValues() {
        let progress = InstallationProgress(
            phase: .copyingFiles,
            phaseProgress: 1.5,
            overallProgress: -0.5
        )

        XCTAssertEqual(progress.phaseProgress, 1.0)
        XCTAssertEqual(progress.overallProgress, 0.0)
    }

    func testInstallationProgress_Properties() {
        let progress = InstallationProgress(
            phase: .installingFeatures,
            phaseProgress: 0.5,
            overallProgress: 0.35,
            message: "Installing...",
            estimatedSecondsRemaining: 120
        )

        XCTAssertEqual(progress.phase, .installingFeatures)
        XCTAssertEqual(progress.phaseProgress, 0.5)
        XCTAssertEqual(progress.overallProgress, 0.35)
        XCTAssertEqual(progress.message, "Installing...")
        XCTAssertEqual(progress.estimatedSecondsRemaining, 120)
    }

    // MARK: - Installation Result Tests

    func testInstallationResult_SuccessProperties() throws {
        let diskPath = try createTestFile(named: "disk.img")

        let result = InstallationResult(
            success: true,
            finalPhase: .complete,
            durationSeconds: 600,
            diskImagePath: diskPath,
            diskUsageBytes: 8_000_000_000
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.finalPhase, .complete)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.durationSeconds, 600)
        XCTAssertEqual(result.diskUsageBytes, 8_000_000_000)
    }

    func testInstallationResult_FailureProperties() throws {
        let diskPath = try createTestFile(named: "disk.img")
        let error = WinRunError.cancelled

        let result = InstallationResult(
            success: false,
            finalPhase: .failed,
            error: error,
            durationSeconds: 120,
            diskImagePath: diskPath
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .failed)
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.diskUsageBytes)
    }

    // MARK: - Installation Lifecycle Tests

    func testStartInstallation_Success() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        let result = try await provisioner.startInstallation(configuration: provConfig)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.finalPhase, .complete)
        XCTAssertNil(result.error)
        XCTAssertGreaterThan(result.durationSeconds, 0)
    }

    func testStartInstallation_WithDelegate() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        let delegate = MockInstallationDelegate()

        let result = try await provisioner.startInstallation(
            configuration: provConfig,
            delegate: delegate
        )

        XCTAssertTrue(result.success)
        XCTAssertGreaterThan(delegate.progressUpdates.count, 0)
        XCTAssertNotNil(delegate.completionResult)
        XCTAssertTrue(delegate.completionResult?.success ?? false)
        XCTAssertEqual(delegate.progressUpdates.first?.phase, .preparing)
        XCTAssertEqual(delegate.progressUpdates.last?.phase, .complete)
    }

    func testStartInstallation_FailsWithMissingISO() async throws {
        let diskPath = try createTestFile(named: "disk.img")
        let isoPath = testDirectory.appendingPathComponent("nonexistent.iso")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        let delegate = MockInstallationDelegate()

        let result = try await provisioner.startInstallation(
            configuration: provConfig,
            delegate: delegate
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .failed)
        XCTAssertNotNil(result.error)
        XCTAssertNotNil(delegate.completionResult)
        XCTAssertFalse(delegate.completionResult?.success ?? true)
    }

    func testCancelInstallation() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            provisioner.cancelInstallation()
        }

        let result = try await provisioner.startInstallation(configuration: provConfig)

        XCTAssertTrue(result.finalPhase.isTerminal)
    }

    func testIsInstalling_InitiallyFalse() {
        XCTAssertFalse(provisioner.isInstalling)
    }
}

// MARK: - Mock Installation Delegate

final class MockInstallationDelegate: InstallationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _progressUpdates: [InstallationProgress] = []
    private var _completionResult: InstallationResult?

    var progressUpdates: [InstallationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _progressUpdates
    }

    var completionResult: InstallationResult? {
        lock.lock()
        defer { lock.unlock() }
        return _completionResult
    }

    func installationDidUpdateProgress(_ progress: InstallationProgress) {
        lock.lock()
        defer { lock.unlock() }
        _progressUpdates.append(progress)
    }

    func installationDidComplete(with result: InstallationResult) {
        lock.lock()
        defer { lock.unlock() }
        _completionResult = result
    }
}
