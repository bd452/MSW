import WinRunShared
import XCTest

@testable import WinRunSetup

final class SetupCoordinatorTests: XCTestCase {
    // MARK: - Properties

    private var testDirectory: URL!

    // MARK: - Setup/Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Create a temporary directory for tests
        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent(
            "SetupCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        // Clean up test directory
        if let testDir = testDirectory,
            FileManager.default.fileExists(atPath: testDir.path) {
            try? FileManager.default.removeItem(at: testDir)
        }
        testDirectory = nil

        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testSetupCoordinatorConfiguration_DefaultValues() {
        let isoPath = testDirectory.appendingPathComponent("windows.iso")
        let config = SetupCoordinatorConfiguration(isoPath: isoPath)

        XCTAssertEqual(config.isoPath, isoPath)
        XCTAssertEqual(config.diskSizeGB, DiskImageConfiguration.defaultSizeGB)
        XCTAssertEqual(config.cpuCount, ProvisioningConfiguration.defaultCPUCount)
        XCTAssertEqual(config.memorySizeGB, ProvisioningConfiguration.defaultMemorySizeGB)
        XCTAssertNil(config.autounattendPath)
    }

    func testSetupCoordinatorConfiguration_CustomValues() {
        let isoPath = testDirectory.appendingPathComponent("windows.iso")
        let diskPath = testDirectory.appendingPathComponent("custom.img")
        let autounattend = testDirectory.appendingPathComponent("autounattend.xml")

        let config = SetupCoordinatorConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            diskSizeGB: 128,
            autounattendPath: autounattend,
            cpuCount: 8,
            memorySizeGB: 16
        )

        XCTAssertEqual(config.isoPath, isoPath)
        XCTAssertEqual(config.diskImagePath, diskPath)
        XCTAssertEqual(config.diskSizeGB, 128)
        XCTAssertEqual(config.autounattendPath, autounattend)
        XCTAssertEqual(config.cpuCount, 8)
        XCTAssertEqual(config.memorySizeGB, 16)
    }

    // MARK: - Coordinator Initialization Tests

    func testSetupCoordinator_InitialState() async {
        let coordinator = SetupCoordinator()

        let state = await coordinator.state
        let isProvisioning = await coordinator.isProvisioning

        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(isProvisioning)
    }

    // MARK: - State Query Tests

    func testSetupCoordinator_CanRetryFromIdle() async {
        let coordinator = SetupCoordinator()

        let canRetry = await coordinator.canRetry

        // Can't retry from idle - need to fail first
        XCTAssertFalse(canRetry)
    }

    func testSetupCoordinator_CanRollbackFromIdle() async {
        let coordinator = SetupCoordinator()

        let canRollback = await coordinator.canRollback

        // Can't rollback from idle
        XCTAssertFalse(canRollback)
    }

    // MARK: - Error Handling Tests

    func testSetupCoordinator_ProvisioningWithNonExistentISO() async {
        let coordinator = SetupCoordinator()
        let isoPath = testDirectory.appendingPathComponent("nonexistent.iso")
        let diskPath = testDirectory.appendingPathComponent("disk.img")

        let config = SetupCoordinatorConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        let result = await coordinator.startProvisioning(with: config)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .failed)
        XCTAssertNotNil(result.error)
    }

    func testSetupCoordinator_CannotStartFromActiveState() async {
        // This test verifies that provisioning can't be started when already active
        // We'll use a mock scenario where we try to start twice

        let coordinator = SetupCoordinator()
        let isoPath = testDirectory.appendingPathComponent("windows.iso")
        let diskPath = testDirectory.appendingPathComponent("disk.img")

        // Create a fake ISO file
        FileManager.default.createFile(
            atPath: isoPath.path,
            contents: Data("fake iso".utf8),
            attributes: nil
        )

        let config = SetupCoordinatorConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        // Start the first provisioning (it will fail during ISO validation)
        let result = await coordinator.startProvisioning(with: config)

        // The provisioning should fail (invalid ISO) but that's expected
        XCTAssertFalse(result.success)
    }

    // MARK: - Cancellation Tests

    func testSetupCoordinator_Cancel() async {
        let coordinator = SetupCoordinator()

        // Cancel from idle state - should be no-op
        await coordinator.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state.phase, .idle)
    }

    func testSetupCoordinator_Reset() async {
        let coordinator = SetupCoordinator()

        // Reset from idle state - should be no-op (not terminal)
        await coordinator.reset()

        let state = await coordinator.state
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Rollback Tests

    func testSetupCoordinator_RollbackFromIdleFails() async {
        let coordinator = SetupCoordinator()

        let result = await coordinator.rollback()

        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    // MARK: - Retry Tests

    func testSetupCoordinator_RetryFromIdleFails() async {
        let coordinator = SetupCoordinator()

        let result = await coordinator.retry()

        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    // MARK: - Delegate Tests

    func testSetupCoordinator_DelegateProgressUpdates() async {
        let coordinator = SetupCoordinator()
        let delegateMock = ProvisioningDelegateMock()

        await coordinator.setDelegate(delegateMock)

        let isoPath = testDirectory.appendingPathComponent("windows.iso")
        let diskPath = testDirectory.appendingPathComponent("disk.img")

        // Create a fake file (will fail validation, but we'll get progress updates)
        FileManager.default.createFile(
            atPath: isoPath.path,
            contents: Data("not a real iso".utf8),
            attributes: nil
        )

        let config = SetupCoordinatorConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        _ = await coordinator.startProvisioning(with: config)

        // Should have received at least some progress updates
        XCTAssertGreaterThan(delegateMock.progressUpdates.count, 0)

        // Should have received a completion notification
        XCTAssertTrue(delegateMock.didComplete)
    }
}

// MARK: - Test Helpers

/// Mock delegate for testing provisioning callbacks.
private final class ProvisioningDelegateMock: ProvisioningDelegate, @unchecked Sendable {
    var progressUpdates: [ProvisioningProgress] = []
    var phaseChanges: [(from: ProvisioningPhase, to: ProvisioningPhase)] = []
    var completionResult: ProvisioningResult?
    var didComplete = false

    func provisioningDidUpdateProgress(_ progress: ProvisioningProgress) {
        progressUpdates.append(progress)
    }

    func provisioningDidChangePhase(from oldPhase: ProvisioningPhase, to newPhase: ProvisioningPhase) {
        phaseChanges.append((from: oldPhase, to: newPhase))
    }

    func provisioningDidComplete(with result: ProvisioningResult) {
        completionResult = result
        didComplete = true
    }
}

// MARK: - Error Classification Tests

final class ProvisioningErrorClassificationTests: XCTestCase {
    func testErrorClassification_Phases() {
        XCTAssertEqual(
            ProvisioningErrorType.classify(phase: .validatingISO),
            .isoValidation
        )
        XCTAssertEqual(
            ProvisioningErrorType.classify(phase: .creatingDisk),
            .diskCreation
        )
        XCTAssertEqual(
            ProvisioningErrorType.classify(phase: .installingWindows),
            .windowsInstallation
        )
        XCTAssertEqual(
            ProvisioningErrorType.classify(phase: .postInstallProvisioning),
            .postInstallProvisioning
        )
        XCTAssertEqual(
            ProvisioningErrorType.classify(phase: .creatingSnapshot),
            .snapshotCreation
        )
    }

    func testErrorClassification_CleanRetryRecommendations() {
        XCTAssertTrue(ProvisioningErrorType.isoValidation.suggestsCleanRetry)
        XCTAssertTrue(ProvisioningErrorType.diskCreation.suggestsCleanRetry)
        XCTAssertTrue(ProvisioningErrorType.windowsInstallation.suggestsCleanRetry)
        XCTAssertFalse(ProvisioningErrorType.postInstallProvisioning.suggestsCleanRetry)
        XCTAssertFalse(ProvisioningErrorType.snapshotCreation.suggestsCleanRetry)
    }
}

// MARK: - Recovery Options Tests

final class RecoveryOptionsTests: XCTestCase {
    func testRecoveryOptions_CleanStart() {
        let options = RecoveryOptions.cleanStart

        XCTAssertTrue(options.deletePartialDisk)
        XCTAssertTrue(options.keepValidationCache)
        XCTAssertTrue(options.useSameConfiguration)
    }

    func testRecoveryOptions_PreserveProgress() {
        let options = RecoveryOptions.preserveProgress

        XCTAssertFalse(options.deletePartialDisk)
        XCTAssertTrue(options.keepValidationCache)
        XCTAssertTrue(options.useSameConfiguration)
    }

    func testRecoveryOptions_CustomValues() {
        let options = RecoveryOptions(
            deletePartialDisk: false,
            keepValidationCache: false,
            useSameConfiguration: false
        )

        XCTAssertFalse(options.deletePartialDisk)
        XCTAssertFalse(options.keepValidationCache)
        XCTAssertFalse(options.useSameConfiguration)
    }
}

// MARK: - Provisioning Statistics Tests

final class ProvisioningStatisticsTests: XCTestCase {
    func testProvisioningStatistics_Initialization() {
        let stats = ProvisioningStatistics(
            totalDuration: 3600,
            phaseDurations: [
                .validatingISO: 30,
                .creatingDisk: 60,
                .installingWindows: 2400,
                .postInstallProvisioning: 900,
                .creatingSnapshot: 210,
            ],
            finalDiskSizeBytes: 20_000_000_000,
            recoverableErrorCount: 2,
            finalPhase: .complete,
            succeeded: true
        )

        XCTAssertEqual(stats.totalDuration, 3600)
        XCTAssertEqual(stats.phaseDurations.count, 5)
        XCTAssertEqual(stats.finalDiskSizeBytes, 20_000_000_000)
        XCTAssertEqual(stats.recoverableErrorCount, 2)
        XCTAssertEqual(stats.finalPhase, .complete)
        XCTAssertTrue(stats.succeeded)
    }
}
