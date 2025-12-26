import Foundation
import WinRunShared

// MARK: - Setup Failure Context

/// Captures detailed context about a setup failure for diagnostics and recovery.
///
/// This struct provides structured information about what went wrong during setup,
/// including the phase that failed, system state, and suggested recovery actions.
public struct SetupFailureContext: Sendable, Equatable {
    /// The phase where the failure occurred.
    public let failedPhase: ProvisioningPhase

    /// The underlying error.
    public let error: WinRunError

    /// Human-readable summary of what went wrong.
    public let summary: String

    /// Technical details for support requests.
    public let technicalDetails: String

    /// Path to the ISO that was being used (if any).
    public let isoPath: URL?

    /// Path to the disk image (if created).
    public let diskImagePath: URL?

    /// Disk usage at time of failure (bytes).
    public let diskUsageBytes: UInt64?

    /// Free disk space at time of failure (bytes).
    public let freeDiskSpaceBytes: UInt64?

    /// Suggested recovery actions based on the failure type.
    public let suggestedActions: [RecoveryActionType]

    /// Whether cleanup is recommended before retry.
    public let cleanupRecommended: Bool

    /// Timestamp when the failure occurred.
    public let occurredAt: Date

    public init(
        failedPhase: ProvisioningPhase,
        error: WinRunError,
        summary: String? = nil,
        technicalDetails: String? = nil,
        isoPath: URL? = nil,
        diskImagePath: URL? = nil,
        diskUsageBytes: UInt64? = nil,
        freeDiskSpaceBytes: UInt64? = nil,
        suggestedActions: [RecoveryActionType]? = nil,
        cleanupRecommended: Bool = false,
        occurredAt: Date = Date()
    ) {
        self.failedPhase = failedPhase
        self.error = error
        self.summary = summary ?? Self.defaultSummary(for: error, phase: failedPhase)
        self.technicalDetails = technicalDetails ?? Self.defaultTechnicalDetails(for: error)
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.diskUsageBytes = diskUsageBytes
        self.freeDiskSpaceBytes = freeDiskSpaceBytes
        self.suggestedActions = suggestedActions ?? Self.defaultSuggestedActions(for: error, phase: failedPhase)
        self.cleanupRecommended = cleanupRecommended
        self.occurredAt = occurredAt
    }

    // MARK: - Factory Methods

    /// Creates a failure context from a provisioning result.
    public static func from(
        result: ProvisioningResult,
        context: ProvisioningContext? = nil
    ) -> SetupFailureContext? {
        guard !result.success, let error = result.error else { return nil }

        let freeDiskSpace = try? getFreeDiskSpace(
            at: context?.diskImagePath ?? DiskImageConfiguration.defaultPath
        )

        return SetupFailureContext(
            failedPhase: result.finalPhase,
            error: error,
            isoPath: context?.isoPath,
            diskImagePath: result.diskImagePath,
            diskUsageBytes: result.diskUsageBytes ?? context?.diskUsageBytes,
            freeDiskSpaceBytes: freeDiskSpace,
            cleanupRecommended: result.finalPhase.isAfter(.creatingDisk)
        )
    }

    // MARK: - Default Generators

    private static func defaultSummary(for error: WinRunError, phase: ProvisioningPhase) -> String {
        switch error {
        case .cancelled:
            return "Setup was cancelled."
        case .configInvalid(let reason):
            return "Configuration issue: \(reason)"
        case .diskFull:
            return "Not enough disk space to complete setup."
        case .networkUnavailable:
            return "Network connection required for setup."
        case .timeout:
            return "The operation timed out. This may be due to a slow or unresponsive ISO."
        case .permissionDenied(let path):
            return "Permission denied accessing \(path)."
        case .internalError(let message):
            return "An unexpected error occurred: \(message)"
        case .vmError(let message):
            return "Virtual machine error: \(message)"
        case .isoValidationFailed(let reason):
            return "ISO validation failed: \(reason)"
        case .spiceConnectionFailed(let reason):
            return "Connection to guest failed: \(reason)"
        case .guestAgentError(let message):
            return "Guest agent error: \(message)"
        case .installationFailed(let phase, let reason):
            return "Installation failed during \(phase): \(reason)"
        case .unexpectedState(let expected, let actual):
            return "Unexpected state: expected \(expected), got \(actual)"
        }
    }

    private static func defaultTechnicalDetails(for error: WinRunError) -> String {
        var parts: [String] = []
        parts.append("Error: \(error.localizedDescription)")
        parts.append("Code: \(error.errorCode)")

        if let nsError = error as NSError? {
            parts.append("Domain: \(nsError.domain)")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                parts.append("Underlying: \(underlying)")
            }
        }

        return parts.joined(separator: "\n")
    }

    private static func defaultSuggestedActions(
        for error: WinRunError,
        phase: ProvisioningPhase
    ) -> [RecoveryActionType] {
        switch error {
        case .cancelled:
            return [.retry]

        case .diskFull:
            return [.freeDiskSpace, .chooseDifferentISO]

        case .isoValidationFailed:
            return [.chooseDifferentISO, .contactSupport]

        case .timeout:
            return [.retry, .chooseDifferentISO, .contactSupport]

        case .networkUnavailable:
            return [.checkNetwork, .retry]

        case .permissionDenied:
            return [.grantPermission, .contactSupport]

        case .configInvalid:
            return [.reviewConfig, .contactSupport]

        default:
            // Default set based on phase
            if phase.isAfter(.validatingISO) {
                return [.retry, .chooseDifferentISO, .contactSupport]
            }
            return [.chooseDifferentISO, .contactSupport]
        }
    }

    private static func getFreeDiskSpace(at url: URL) throws -> UInt64 {
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

// MARK: - Recovery Action Type

/// Types of recovery actions that can be suggested.
public enum RecoveryActionType: String, Sendable, CaseIterable {
    case retry = "retry"
    case chooseDifferentISO = "choose_different_iso"
    case freeDiskSpace = "free_disk_space"
    case checkNetwork = "check_network"
    case grantPermission = "grant_permission"
    case reviewConfig = "review_config"
    case contactSupport = "contact_support"
    case rollback = "rollback"

    public var displayName: String {
        switch self {
        case .retry: return "Retry setup"
        case .chooseDifferentISO: return "Choose a different ISO"
        case .freeDiskSpace: return "Free up disk space"
        case .checkNetwork: return "Check network connection"
        case .grantPermission: return "Grant permission"
        case .reviewConfig: return "Review configuration"
        case .contactSupport: return "Contact support"
        case .rollback: return "Clean up and start over"
        }
    }

    public var helpText: String {
        switch self {
        case .retry:
            return "Try again with the same settings."
        case .chooseDifferentISO:
            return "Select a different Windows 11 ARM64 ISO file."
        case .freeDiskSpace:
            return "Delete files to make room for the Windows installation (~64GB needed)."
        case .checkNetwork:
            return "Ensure you have an active internet connection."
        case .grantPermission:
            return "Check System Settings → Privacy & Security for required permissions."
        case .reviewConfig:
            return "Check the configuration file for issues."
        case .contactSupport:
            return "Open the WinRun issue tracker for help."
        case .rollback:
            return "Delete the partial installation and start fresh."
        }
    }
}

// MARK: - ProvisioningPhase Extension

extension ProvisioningPhase {
    /// Returns whether this phase is after the given phase in the provisioning flow.
    public func isAfter(_ other: ProvisioningPhase) -> Bool {
        let orderedPhases: [ProvisioningPhase] = [
            .idle, .validatingISO, .creatingDisk, .installingWindows,
            .postInstallProvisioning, .creatingSnapshot, .complete,
        ]

        guard let selfIndex = orderedPhases.firstIndex(of: self),
              let otherIndex = orderedPhases.firstIndex(of: other) else {
            return false
        }

        return selfIndex > otherIndex
    }
}

// MARK: - WinRunError Extension

extension WinRunError {
    /// Error code for diagnostic purposes.
    public var errorCode: Int {
        switch self {
        case .cancelled: return 1
        case .configInvalid: return 2
        case .diskFull: return 3
        case .networkUnavailable: return 4
        case .timeout: return 5
        case .permissionDenied: return 6
        case .internalError: return 7
        case .vmError: return 8
        case .isoValidationFailed: return 9
        case .spiceConnectionFailed: return 10
        case .guestAgentError: return 11
        case .installationFailed: return 12
        case .unexpectedState: return 13
        }
    }
}
