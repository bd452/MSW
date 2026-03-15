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

        provisioner = VMProvisioner(allowSimulation: true)
    }

    override func tearDown() async throws {
        if let testDirectory = testDirectory,
            FileManager.default.fileExists(atPath: testDirectory.path) {
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

    func testCancelInstallationDuringBootingReturnsCancelledResult() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        let localProvisioner = provisioner!
        let delegate = CancellingInstallationDelegate(targetPhase: .booting) {
            localProvisioner.cancelInstallation()
        }

        let result = try await localProvisioner.startInstallation(
            configuration: provConfig,
            delegate: delegate
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .cancelled)
        if case .cancelled? = result.error {
            // Expected
        } else {
            XCTFail("Expected cancelled error, got \(String(describing: result.error))")
        }
        XCTAssertTrue(delegate.observedPhases.contains(.booting))
    }

    func testInstallationProgressIncludesExpectedPhasesInOrder() async throws {
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

        let expectedOrder: [InstallationPhase] = [
            .preparing, .booting, .copyingFiles, .installingFeatures, .firstBoot, .postInstall, .complete,
        ]
        let condensedPhases = delegate.progressUpdates.reduce(into: [InstallationPhase]()) { phases, progress in
            if phases.last != progress.phase {
                phases.append(progress.phase)
            }
        }

        var expectedIndex = 0
        for phase in condensedPhases where expectedIndex < expectedOrder.count {
            if phase == expectedOrder[expectedIndex] {
                expectedIndex += 1
            }
        }
        XCTAssertEqual(
            expectedIndex,
            expectedOrder.count,
            "Observed phase sequence \(condensedPhases) should include all expected phases in order"
        )

        for (previous, next) in zip(delegate.progressUpdates, delegate.progressUpdates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next.overallProgress + 1e-9,
                previous.overallProgress,
                "Overall progress must be monotonic for setup lifecycle"
            )
        }
    }

    func testInstallToFirstBootTransitionOccursInOrder() async throws {
        let delegate = try await runInstallationWithDelegate()

        guard
            let firstInstallingFeaturesIndex = delegate.progressUpdates.firstIndex(where: { $0.phase == .installingFeatures }),
            let firstFirstBootIndex = delegate.progressUpdates.firstIndex(where: { $0.phase == .firstBoot })
        else {
            XCTFail("Expected installingFeatures and firstBoot phase updates")
            return
        }

        XCTAssertLessThan(
            firstInstallingFeaturesIndex,
            firstFirstBootIndex,
            "installingFeatures should occur before firstBoot"
        )
    }

    func testFirstBootProgressIncrementsAndMessageIsSet() async throws {
        let delegate = try await runInstallationWithDelegate()

        let firstBootUpdates = delegate.progressUpdates.filter { $0.phase == .firstBoot }
        XCTAssertEqual(firstBootUpdates.count, 10, "Simulation should emit 10 progress steps for firstBoot")

        var previousPhaseProgress = 0.0
        for update in firstBootUpdates {
            XCTAssertGreaterThan(
                update.phaseProgress,
                previousPhaseProgress,
                "firstBoot phaseProgress should increase monotonically"
            )
            XCTAssertEqual(update.message, "Completing first-time setup...")
            previousPhaseProgress = update.phaseProgress
        }

        XCTAssertEqual(firstBootUpdates.last?.phaseProgress, 1.0, accuracy: 0.0001)
    }

    func testCancelAtFirstBootDoesNotContinueToPostInstall() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        let localProvisioner = provisioner!
        let delegate = CancellingInstallationDelegate(targetPhase: .firstBoot) {
            localProvisioner.cancelInstallation()
        }

        let result = try await localProvisioner.startInstallation(
            configuration: provConfig,
            delegate: delegate
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.finalPhase.isTerminal)
        XCTAssertTrue(delegate.observedPhases.contains(.firstBoot))
        XCTAssertFalse(delegate.observedPhases.contains(.postInstall))
        XCTAssertFalse(delegate.observedPhases.contains(.complete))
    }

    func testIsInstalling_InitiallyFalse() {
        XCTAssertFalse(provisioner.isInstalling)
    }

    // MARK: - Shared Test Helpers

    private func runInstallationWithDelegate() async throws -> MockInstallationDelegate {
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
        return delegate
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

final class CancellingInstallationDelegate: InstallationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let targetPhase: InstallationPhase
    private let cancelAction: @Sendable () -> Void
    private var cancelled = false
    private var _observedPhases: [InstallationPhase] = []

    init(targetPhase: InstallationPhase, cancelAction: @escaping @Sendable () -> Void) {
        self.targetPhase = targetPhase
        self.cancelAction = cancelAction
    }

    var observedPhases: [InstallationPhase] {
        lock.lock()
        defer { lock.unlock() }
        return _observedPhases
    }

    func installationDidUpdateProgress(_ progress: InstallationProgress) {
        lock.lock()
        _observedPhases.append(progress.phase)
        let shouldCancel = !cancelled && progress.phase == targetPhase
        if shouldCancel {
            cancelled = true
        }
        lock.unlock()

        if shouldCancel {
            cancelAction()
        }
    }

    func installationDidComplete(with result: InstallationResult) {}
}
