import Foundation
import WinRunShared

// MARK: - Provisioning Phase

/// High-level phases of the end-to-end Windows provisioning flow.
///
/// This represents the entire setup journey from ISO validation to a ready-to-use VM.
/// For granular Windows installation phases (copying files, OOBE, etc.), see `InstallationPhase`.
public enum ProvisioningPhase: String, Sendable, CaseIterable, Codable {
    case idle = "idle"
    case validatingISO = "validating_iso"
    case creatingDisk = "creating_disk"
    case installingWindows = "installing_windows"
    case postInstallProvisioning = "post_install_provisioning"
    case creatingSnapshot = "creating_snapshot"
    case complete = "complete"
    case failed = "failed"
    case cancelled = "cancelled"

    public var displayName: String {
        switch self {
        case .idle: return "Ready to start"
        case .validatingISO: return "Validating Windows ISO"
        case .creatingDisk: return "Creating disk image"
        case .installingWindows: return "Installing Windows"
        case .postInstallProvisioning: return "Configuring Windows"
        case .creatingSnapshot: return "Finalizing"
        case .complete: return "Setup complete"
        case .failed: return "Setup failed"
        case .cancelled: return "Setup cancelled"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .complete, .failed, .cancelled: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .validatingISO, .creatingDisk, .installingWindows,
            .postInstallProvisioning, .creatingSnapshot:
            return true
        default:
            return false
        }
    }

    public var progressWeight: Double {
        switch self {
        case .idle: return 0.0
        case .validatingISO: return 0.02
        case .creatingDisk: return 0.03
        case .installingWindows: return 0.60
        case .postInstallProvisioning: return 0.25
        case .creatingSnapshot: return 0.10
        case .complete, .failed, .cancelled: return 0.0
        }
    }
}

// MARK: - Provisioning State

/// Current state of the provisioning state machine.
public struct ProvisioningState: Sendable, Equatable {
    public let phase: ProvisioningPhase
    public let phaseProgress: Double
    public let message: String
    public let error: WinRunError?
    public let enteredAt: Date

    public init(
        phase: ProvisioningPhase,
        phaseProgress: Double = 0.0,
        message: String = "",
        error: WinRunError? = nil,
        enteredAt: Date = Date()
    ) {
        self.phase = phase
        self.phaseProgress = min(1.0, max(0.0, phaseProgress))
        self.message = message.isEmpty ? phase.displayName : message
        self.error = error
        self.enteredAt = enteredAt
    }

    public static var idle: ProvisioningState {
        ProvisioningState(phase: .idle)
    }

    public var overallProgress: Double {
        let phases: [ProvisioningPhase] = [
            .validatingISO, .creatingDisk, .installingWindows,
            .postInstallProvisioning, .creatingSnapshot,
        ]
        var progress = 0.0
        for p in phases {
            if phase == p {
                progress += p.progressWeight * phaseProgress
                break
            } else if phase == .complete {
                progress += p.progressWeight
            } else if let ci = phases.firstIndex(of: phase),
                let pi = phases.firstIndex(of: p), pi < ci {
                progress += p.progressWeight
            }
        }
        return min(1.0, progress)
    }
}

// MARK: - State Transitions

public struct ProvisioningStateTransition {
    private static let validTransitions: [ProvisioningPhase: Set<ProvisioningPhase>] = [
        .idle: [.validatingISO, .cancelled],
        .validatingISO: [.creatingDisk, .failed, .cancelled],
        .creatingDisk: [.installingWindows, .failed, .cancelled],
        .installingWindows: [.postInstallProvisioning, .failed, .cancelled],
        .postInstallProvisioning: [.creatingSnapshot, .failed, .cancelled],
        .creatingSnapshot: [.complete, .failed, .cancelled],
        .complete: [],
        .failed: [.idle],
        .cancelled: [.idle],
    ]

    public static func isValid(from: ProvisioningPhase, to: ProvisioningPhase) -> Bool {
        validTransitions[from]?.contains(to) ?? false
    }

    public static func validNextPhases(from phase: ProvisioningPhase) -> Set<ProvisioningPhase> {
        validTransitions[phase] ?? []
    }

    public static func transition(
        from state: ProvisioningState,
        to phase: ProvisioningPhase,
        message: String = "",
        error: WinRunError? = nil
    ) -> Result<ProvisioningState, WinRunError> {
        guard isValid(from: state.phase, to: phase) else {
            return .failure(.stateTransitionInvalid(from: state.phase.rawValue, to: phase.rawValue))
        }
        return .success(ProvisioningState(phase: phase, phaseProgress: 0.0, message: message, error: error))
    }
}

// MARK: - Provisioning Context

public struct ProvisioningContext: Sendable, Equatable {
    public let isoPath: URL
    public let diskImagePath: URL
    public var isoValidation: ISOValidationResult?
    public var diskCreationResult: DiskCreationResult?
    public var windowsVersion: String?
    public var agentVersion: String?
    public var diskUsageBytes: UInt64?
    public let startedAt: Date

    public init(isoPath: URL, diskImagePath: URL, startedAt: Date = Date()) {
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.startedAt = startedAt
    }

    public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
}

// MARK: - Disk Creation Result

public struct DiskCreationResult: Sendable, Equatable {
    public let path: URL
    public let requestedSizeBytes: UInt64
    public let isSparse: Bool

    public init(path: URL, requestedSizeBytes: UInt64, isSparse: Bool = true) {
        self.path = path
        self.requestedSizeBytes = requestedSizeBytes
        self.isSparse = isSparse
    }
}

// MARK: - Provisioning Progress

public struct ProvisioningProgress: Sendable, Equatable {
    public let phase: ProvisioningPhase
    public let phaseProgress: Double
    public let overallProgress: Double
    public let message: String
    public let estimatedSecondsRemaining: Int?

    /// The current sub-phase within `installingWindows` phase (nil for other phases).
    public let installationSubPhase: InstallationPhase?

    /// Progress within the current sub-phase (0.0 to 1.0).
    public let subPhaseProgress: Double?

    public init(
        phase: ProvisioningPhase,
        phaseProgress: Double = 0.0,
        overallProgress: Double = 0.0,
        message: String = "",
        estimatedSecondsRemaining: Int? = nil,
        installationSubPhase: InstallationPhase? = nil,
        subPhaseProgress: Double? = nil
    ) {
        self.phase = phase
        self.phaseProgress = min(1.0, max(0.0, phaseProgress))
        self.overallProgress = min(1.0, max(0.0, overallProgress))
        self.message = message.isEmpty ? phase.displayName : message
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.installationSubPhase = installationSubPhase
        self.subPhaseProgress = subPhaseProgress
    }

    public init(from state: ProvisioningState, estimatedSecondsRemaining: Int? = nil) {
        self.phase = state.phase
        self.phaseProgress = state.phaseProgress
        self.overallProgress = state.overallProgress
        self.message = state.message
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.installationSubPhase = nil
        self.subPhaseProgress = nil
    }

    /// Creates a progress update with installation sub-phase information.
    public static func withInstallationSubPhase(
        phase: ProvisioningPhase,
        phaseProgress: Double,
        overallProgress: Double,
        message: String,
        installationPhase: InstallationPhase,
        subPhaseProgress: Double
    ) -> ProvisioningProgress {
        ProvisioningProgress(
            phase: phase,
            phaseProgress: phaseProgress,
            overallProgress: overallProgress,
            message: message,
            estimatedSecondsRemaining: nil,
            installationSubPhase: installationPhase,
            subPhaseProgress: subPhaseProgress
        )
    }
}

// MARK: - Provisioning Result

public struct ProvisioningResult: Sendable {
    public let success: Bool
    public let finalPhase: ProvisioningPhase
    public let error: WinRunError?
    public let durationSeconds: TimeInterval
    public let diskImagePath: URL
    public let diskUsageBytes: UInt64?
    public let windowsVersion: String?
    public let agentVersion: String?

    public init(
        success: Bool,
        finalPhase: ProvisioningPhase,
        error: WinRunError? = nil,
        durationSeconds: TimeInterval,
        diskImagePath: URL,
        diskUsageBytes: UInt64? = nil,
        windowsVersion: String? = nil,
        agentVersion: String? = nil
    ) {
        self.success = success
        self.finalPhase = finalPhase
        self.error = error
        self.durationSeconds = durationSeconds
        self.diskImagePath = diskImagePath
        self.diskUsageBytes = diskUsageBytes
        self.windowsVersion = windowsVersion
        self.agentVersion = agentVersion
    }

    public static func success(from context: ProvisioningContext) -> ProvisioningResult {
        ProvisioningResult(
            success: true,
            finalPhase: .complete,
            durationSeconds: context.elapsed,
            diskImagePath: context.diskImagePath,
            diskUsageBytes: context.diskUsageBytes,
            windowsVersion: context.windowsVersion,
            agentVersion: context.agentVersion
        )
    }

    public static func failure(
        phase: ProvisioningPhase,
        error: WinRunError,
        context: ProvisioningContext
    ) -> ProvisioningResult {
        ProvisioningResult(
            success: false,
            finalPhase: phase,
            error: error,
            durationSeconds: context.elapsed,
            diskImagePath: context.diskImagePath
        )
    }

    public static func cancelled(context: ProvisioningContext) -> ProvisioningResult {
        ProvisioningResult(
            success: false,
            finalPhase: .cancelled,
            error: .cancelled,
            durationSeconds: context.elapsed,
            diskImagePath: context.diskImagePath
        )
    }
}

// MARK: - Rollback Result

public struct RollbackResult: Sendable {
    public let success: Bool
    public let freedBytes: UInt64
    public let error: WinRunError?

    public var description: String {
        if success {
            if freedBytes > 0 {
                return "Rollback complete. Freed \(freedBytes / (1024 * 1024)) MB."
            }
            return "Rollback complete. No disk image to delete."
        }
        return "Rollback failed: \(error?.localizedDescription ?? "Unknown error")"
    }

    public init(success: Bool, freedBytes: UInt64, error: WinRunError?) {
        self.success = success
        self.freedBytes = freedBytes
        self.error = error
    }
}

// MARK: - Provisioning Delegate

public protocol ProvisioningDelegate: AnyObject, Sendable {
    func provisioningDidUpdateProgress(_ progress: ProvisioningProgress)
    func provisioningDidChangePhase(from oldPhase: ProvisioningPhase, to newPhase: ProvisioningPhase)
    func provisioningDidComplete(with result: ProvisioningResult)
}

// MARK: - WinRunError Extension

extension WinRunError {
    public static func stateTransitionInvalid(from: String, to: String) -> WinRunError {
        .configInvalid(reason: "Invalid state transition from '\(from)' to '\(to)'")
    }
}
