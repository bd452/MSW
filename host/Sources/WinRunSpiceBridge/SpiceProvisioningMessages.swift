import Foundation
import WinRunShared

// MARK: - Provisioning Messages

// Note: GuestProvisioningPhase enum is defined in Protocol.generated.swift

/// Extension to add display names for provisioning phases.
extension GuestProvisioningPhase {
    /// User-friendly display name.
    public var displayName: String {
        switch self {
        case .drivers: return "Installing drivers"
        case .agent: return "Installing WinRun Agent"
        case .optimize: return "Optimizing Windows"
        case .finalize: return "Finalizing"
        case .complete: return "Complete"
        }
    }
}

/// Progress update during guest provisioning.
///
/// Sent by the guest during post-install provisioning to report progress
/// on driver installation, agent setup, and Windows optimization.
public struct ProvisionProgressMessage: GuestMessage, Sendable {
    public let timestamp: Int64

    /// Current provisioning phase.
    public let phase: GuestProvisioningPhase

    /// Progress within the current phase (0-100).
    public let percent: UInt8

    /// Human-readable status message.
    public let message: String

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        phase: GuestProvisioningPhase,
        percent: UInt8,
        message: String
    ) {
        self.timestamp = timestamp
        self.phase = phase
        self.percent = min(100, percent)
        self.message = message
    }

    /// Progress as a fraction (0.0 to 1.0).
    public var progressFraction: Double {
        Double(percent) / 100.0
    }
}

/// Error during guest provisioning.
///
/// Sent when a provisioning step fails. The host may choose to retry,
/// continue with warnings, or abort provisioning.
public struct ProvisionErrorMessage: GuestMessage, Sendable {
    public let timestamp: Int64

    /// Phase where the error occurred.
    public let phase: GuestProvisioningPhase

    /// Windows error code (HRESULT or Win32 error).
    public let errorCode: UInt32

    /// Human-readable error message.
    public let message: String

    /// Whether provisioning can continue despite this error.
    public let isRecoverable: Bool

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        phase: GuestProvisioningPhase,
        errorCode: UInt32,
        message: String,
        isRecoverable: Bool = false
    ) {
        self.timestamp = timestamp
        self.phase = phase
        self.errorCode = errorCode
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

/// Provisioning completion notification.
///
/// Sent when guest provisioning completes successfully or fails terminally.
/// Contains final status information about the provisioned VM.
public struct ProvisionCompleteMessage: GuestMessage, Sendable {
    public let timestamp: Int64

    /// Whether provisioning completed successfully.
    public let success: Bool

    /// Disk space used by Windows in megabytes.
    public let diskUsageMB: UInt64

    /// Windows version string (e.g., "Windows 11 23H2").
    public let windowsVersion: String

    /// WinRun Agent version installed.
    public let agentVersion: String

    /// Error message if provisioning failed.
    public let errorMessage: String?

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        success: Bool,
        diskUsageMB: UInt64,
        windowsVersion: String,
        agentVersion: String,
        errorMessage: String? = nil
    ) {
        self.timestamp = timestamp
        self.success = success
        self.diskUsageMB = diskUsageMB
        self.windowsVersion = windowsVersion
        self.agentVersion = agentVersion
        self.errorMessage = errorMessage
    }

    /// Disk usage in bytes.
    public var diskUsageBytes: UInt64 {
        diskUsageMB * 1024 * 1024
    }
}
