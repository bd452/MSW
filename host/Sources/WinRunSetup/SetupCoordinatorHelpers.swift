import Foundation
import WinRunShared

// MARK: - Installation Progress Adapter

/// Adapter to forward InstallationDelegate calls to a closure.
final class InstallationProgressAdapter: InstallationDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (InstallationProgress) -> Void

    init(onProgress: @escaping @Sendable (InstallationProgress) -> Void) {
        self.onProgress = onProgress
    }

    func installationDidUpdateProgress(_ progress: InstallationProgress) {
        onProgress(progress)
    }

    func installationDidComplete(with result: InstallationResult) {
        // Completion is handled by the coordinator
    }
}

// MARK: - Recovery Options

/// Options for recovering from a failed provisioning attempt.
public struct RecoveryOptions: Sendable {
    /// Whether to delete the partial disk image.
    public let deletePartialDisk: Bool

    /// Whether to keep the ISO validation results for retry.
    public let keepValidationCache: Bool

    /// Whether to use the same configuration for retry.
    public let useSameConfiguration: Bool

    /// Default recovery options (clean start).
    public static let cleanStart = RecoveryOptions(
        deletePartialDisk: true,
        keepValidationCache: true,
        useSameConfiguration: true
    )

    /// Recovery options that preserve partial work.
    public static let preserveProgress = RecoveryOptions(
        deletePartialDisk: false,
        keepValidationCache: true,
        useSameConfiguration: true
    )

    public init(
        deletePartialDisk: Bool = true,
        keepValidationCache: Bool = true,
        useSameConfiguration: Bool = true
    ) {
        self.deletePartialDisk = deletePartialDisk
        self.keepValidationCache = keepValidationCache
        self.useSameConfiguration = useSameConfiguration
    }
}

// MARK: - Provisioning Error Classification

/// Classification of provisioning errors for recovery decisions.
public enum ProvisioningErrorType: Sendable {
    /// Error during ISO validation - retry with different ISO
    case isoValidation

    /// Error during disk creation - check disk space, retry
    case diskCreation

    /// Error during Windows installation - may need fresh start
    case windowsInstallation

    /// Error during post-install provisioning - may be recoverable
    case postInstallProvisioning

    /// Error during snapshot creation - installation may still be usable
    case snapshotCreation

    /// Unknown or internal error
    case unknown

    /// Whether this error type suggests the disk should be deleted on retry.
    public var suggestsCleanRetry: Bool {
        switch self {
        case .isoValidation:
            return true  // Invalid ISO, need fresh start
        case .diskCreation:
            return true  // Disk may be corrupted
        case .windowsInstallation:
            return true  // Partial Windows install is unusable
        case .postInstallProvisioning:
            return false  // Windows is installed, may be salvageable
        case .snapshotCreation:
            return false  // Installation complete, just no snapshot
        case .unknown:
            return true  // Be safe
        }
    }

    /// Classifies an error based on the phase where it occurred.
    public static func classify(phase: ProvisioningPhase) -> ProvisioningErrorType {
        switch phase {
        case .idle, .cancelled:
            return .unknown
        case .validatingISO:
            return .isoValidation
        case .creatingDisk:
            return .diskCreation
        case .installingWindows:
            return .windowsInstallation
        case .postInstallProvisioning:
            return .postInstallProvisioning
        case .creatingSnapshot:
            return .snapshotCreation
        case .complete, .failed:
            return .unknown
        }
    }
}

// MARK: - Provisioning Statistics

/// Statistics about a provisioning attempt for diagnostics.
public struct ProvisioningStatistics: Sendable {
    /// Total duration of the provisioning attempt.
    public let totalDuration: TimeInterval

    /// Duration spent in each phase.
    public let phaseDurations: [ProvisioningPhase: TimeInterval]

    /// Final disk size in bytes.
    public let finalDiskSizeBytes: UInt64?

    /// Number of recoverable errors encountered.
    public let recoverableErrorCount: Int

    /// Phase where provisioning stopped.
    public let finalPhase: ProvisioningPhase

    /// Whether provisioning succeeded.
    public let succeeded: Bool

    public init(
        totalDuration: TimeInterval,
        phaseDurations: [ProvisioningPhase: TimeInterval] = [:],
        finalDiskSizeBytes: UInt64? = nil,
        recoverableErrorCount: Int = 0,
        finalPhase: ProvisioningPhase,
        succeeded: Bool
    ) {
        self.totalDuration = totalDuration
        self.phaseDurations = phaseDurations
        self.finalDiskSizeBytes = finalDiskSizeBytes
        self.recoverableErrorCount = recoverableErrorCount
        self.finalPhase = finalPhase
        self.succeeded = succeeded
    }
}
