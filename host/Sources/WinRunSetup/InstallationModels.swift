import Foundation
import WinRunShared

// MARK: - Installation Phase

/// Phases of the Windows installation lifecycle.
public enum InstallationPhase: String, Sendable, CaseIterable {
    /// Preparing disk and configuration.
    case preparing = "preparing"

    /// Booting from ISO and starting Windows Setup.
    case booting = "booting"

    /// Windows Setup is copying files.
    case copyingFiles = "copying_files"

    /// Windows Setup is installing features.
    case installingFeatures = "installing_features"

    /// First boot after installation (OOBE).
    case firstBoot = "first_boot"

    /// Running post-install provisioning scripts.
    case postInstall = "post_install"

    /// Installation completed successfully.
    case complete = "complete"

    /// Installation failed.
    case failed = "failed"

    /// Installation was cancelled.
    case cancelled = "cancelled"

    /// User-friendly description of the phase.
    public var displayName: String {
        switch self {
        case .preparing: return "Preparing installation"
        case .booting: return "Starting Windows Setup"
        case .copyingFiles: return "Copying Windows files"
        case .installingFeatures: return "Installing Windows features"
        case .firstBoot: return "Completing first-time setup"
        case .postInstall: return "Configuring Windows"
        case .complete: return "Installation complete"
        case .failed: return "Installation failed"
        case .cancelled: return "Installation cancelled"
        }
    }

    /// Whether this phase represents a terminal state.
    public var isTerminal: Bool {
        switch self {
        case .complete, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

// MARK: - Installation Progress

/// Progress update during Windows installation.
public struct InstallationProgress: Sendable {
    /// Current installation phase.
    public let phase: InstallationPhase

    /// Progress within the current phase (0.0 to 1.0).
    public let phaseProgress: Double

    /// Overall installation progress (0.0 to 1.0).
    public let overallProgress: Double

    /// Human-readable status message.
    public let message: String

    /// Estimated time remaining in seconds (nil if unknown).
    public let estimatedSecondsRemaining: Int?

    public init(
        phase: InstallationPhase,
        phaseProgress: Double = 0,
        overallProgress: Double = 0,
        message: String = "",
        estimatedSecondsRemaining: Int? = nil
    ) {
        self.phase = phase
        self.phaseProgress = min(1.0, max(0.0, phaseProgress))
        self.overallProgress = min(1.0, max(0.0, overallProgress))
        self.message = message
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }
}

// MARK: - Installation Result

/// Result of a completed installation attempt.
public struct InstallationResult: Sendable {
    /// Whether installation succeeded.
    public let success: Bool

    /// Final installation phase.
    public let finalPhase: InstallationPhase

    /// Error if installation failed.
    public let error: WinRunError?

    /// Total installation duration in seconds.
    public let durationSeconds: TimeInterval

    /// Path to the installed disk image.
    public let diskImagePath: URL

    /// Disk space used by the installation in bytes.
    public let diskUsageBytes: UInt64?

    public init(
        success: Bool,
        finalPhase: InstallationPhase,
        error: WinRunError? = nil,
        durationSeconds: TimeInterval,
        diskImagePath: URL,
        diskUsageBytes: UInt64? = nil
    ) {
        self.success = success
        self.finalPhase = finalPhase
        self.error = error
        self.durationSeconds = durationSeconds
        self.diskImagePath = diskImagePath
        self.diskUsageBytes = diskUsageBytes
    }
}

// MARK: - Installation Delegate

/// Delegate protocol for receiving installation lifecycle updates.
public protocol InstallationDelegate: AnyObject, Sendable {
    /// Called when installation progress is updated.
    func installationDidUpdateProgress(_ progress: InstallationProgress)

    /// Called when installation completes (successfully or with failure).
    func installationDidComplete(with result: InstallationResult)
}

// MARK: - Installation Phase Info

/// Information about an installation phase for progress tracking.
struct InstallationPhaseInfo {
    let phase: InstallationPhase
    let weight: Double
    let message: String
}

// MARK: - Installation Task Holder

/// Thread-safe holder for installation task state.
final class InstallationTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var _isRunning = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        _isCancelled = true
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        _isRunning = true
        _isCancelled = false
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        _isRunning = false
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _isCancelled = false
        _isRunning = false
    }
}
