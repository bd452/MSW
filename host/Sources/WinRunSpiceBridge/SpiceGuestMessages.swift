import Foundation
import WinRunShared

// MARK: - Guest Message Protocol

/// Base protocol for messages received from guest.
public protocol GuestMessage: Codable {
    /// Timestamp when the message was created (Unix milliseconds)
    var timestamp: Int64 { get }
}

// MARK: - Supporting Types

/// Window event type from guest.
/// Values must match guest's WindowEventType enum exactly for protocol compatibility.
public enum WindowEventType: Int32, Codable {
    case created = 0
    case destroyed = 1
    case moved = 2
    case titleChanged = 3
    case focusChanged = 4
    case minimized = 5
    case restored = 6
    case updated = 7
}

/// Rectangle bounds information (matching guest's RectInfo).
public struct RectInfo: Codable, Hashable {
    public let x: Int32
    public let y: Int32
    public let width: Int32
    public let height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Pixel format for frame data.
public enum SpicePixelFormat: UInt8, Codable {
    case bgra32 = 0
    case rgba32 = 1
}

/// Monitor/display information.
public struct MonitorInfo: Codable, Hashable {
    public let deviceName: String
    public let bounds: RectInfo
    public let workArea: RectInfo
    public let dpi: Int32
    public let scaleFactor: Double
    public let isPrimary: Bool

    public init(
        deviceName: String,
        bounds: RectInfo,
        workArea: RectInfo,
        dpi: Int32,
        scaleFactor: Double,
        isPrimary: Bool
    ) {
        self.deviceName = deviceName
        self.bounds = bounds
        self.workArea = workArea
        self.dpi = dpi
        self.scaleFactor = scaleFactor
        self.isPrimary = isPrimary
    }
}

// MARK: - Guest → Host Messages

/// Guest capability announcement sent during handshake.
public struct CapabilityFlagsMessage: GuestMessage {
    public let timestamp: Int64
    public let capabilities: GuestCapabilities
    public let protocolVersion: UInt32
    public let agentVersion: String
    public let osVersion: String

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        capabilities: GuestCapabilities,
        protocolVersion: UInt32,
        agentVersion: String = "1.0.0",
        osVersion: String = ""
    ) {
        self.timestamp = timestamp
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.osVersion = osVersion
    }

    /// Check if the guest protocol version is compatible with this host
    public var isCompatible: Bool {
        SpiceProtocolVersion.isCompatible(with: protocolVersion)
    }
}

/// Window metadata update from guest.
public struct WindowMetadataMessage: GuestMessage {
    public let timestamp: Int64
    public let windowId: UInt64
    public let title: String
    public let bounds: RectInfo
    public let eventType: WindowEventType
    public let processId: UInt32
    public let className: String?
    public let isMinimized: Bool
    public let isResizable: Bool
    public let scaleFactor: Double

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        windowId: UInt64,
        title: String,
        bounds: RectInfo,
        eventType: WindowEventType,
        processId: UInt32 = 0,
        className: String? = nil,
        isMinimized: Bool = false,
        isResizable: Bool = true,
        scaleFactor: Double = 1.0
    ) {
        self.timestamp = timestamp
        self.windowId = windowId
        self.title = title
        self.bounds = bounds
        self.eventType = eventType
        self.processId = processId
        self.className = className
        self.isMinimized = isMinimized
        self.isResizable = isResizable
        self.scaleFactor = scaleFactor
    }
}

/// Frame data header from guest (actual pixel data follows separately).
public struct FrameDataMessage: GuestMessage {
    public let timestamp: Int64
    public let windowId: UInt64
    public let width: Int32
    public let height: Int32
    public let stride: Int32
    public let format: SpicePixelFormat
    public let dataLength: UInt32
    public let frameNumber: UInt32
    public let isKeyFrame: Bool

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        windowId: UInt64,
        width: Int32,
        height: Int32,
        stride: Int32,
        format: SpicePixelFormat,
        dataLength: UInt32,
        frameNumber: UInt32,
        isKeyFrame: Bool = true
    ) {
        self.timestamp = timestamp
        self.windowId = windowId
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.dataLength = dataLength
        self.frameNumber = frameNumber
        self.isKeyFrame = isKeyFrame
    }
}

/// DPI and display information from guest.
public struct DpiInfoMessage: GuestMessage {
    public let timestamp: Int64
    public let primaryDpi: Int32
    public let scaleFactor: Double
    public let monitors: [MonitorInfo]

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        primaryDpi: Int32,
        scaleFactor: Double,
        monitors: [MonitorInfo]
    ) {
        self.timestamp = timestamp
        self.primaryDpi = primaryDpi
        self.scaleFactor = scaleFactor
        self.monitors = monitors
    }
}

/// Icon data extracted from an executable.
public struct IconDataMessage: GuestMessage {
    public let timestamp: Int64
    public let executablePath: String
    public let width: Int32
    public let height: Int32
    public let pngData: Data
    public let iconHash: String?
    public let iconIndex: Int32
    public let wasScaled: Bool

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        executablePath: String,
        width: Int32,
        height: Int32,
        pngData: Data,
        iconHash: String? = nil,
        iconIndex: Int32 = 0,
        wasScaled: Bool = false
    ) {
        self.timestamp = timestamp
        self.executablePath = executablePath
        self.width = width
        self.height = height
        self.pngData = pngData
        self.iconHash = iconHash
        self.iconIndex = iconIndex
        self.wasScaled = wasScaled
    }
}

/// Shortcut detection notification from guest.
public struct ShortcutDetectedMessage: GuestMessage {
    public let timestamp: Int64
    public let shortcutPath: String
    public let targetPath: String
    public let displayName: String?
    public let iconPath: String?
    public let iconIndex: Int32
    public let arguments: String?
    public let workingDirectory: String?
    public let isNew: Bool

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        shortcutPath: String,
        targetPath: String,
        displayName: String? = nil,
        iconPath: String? = nil,
        iconIndex: Int32 = 0,
        arguments: String? = nil,
        workingDirectory: String? = nil,
        isNew: Bool = true
    ) {
        self.timestamp = timestamp
        self.shortcutPath = shortcutPath
        self.targetPath = targetPath
        self.displayName = displayName
        self.iconPath = iconPath
        self.iconIndex = iconIndex
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.isNew = isNew
    }
}

/// Clipboard change notification from guest.
public struct GuestClipboardMessage: GuestMessage {
    public let timestamp: Int64
    public let format: ClipboardFormat
    public let data: Data
    public let sequenceNumber: UInt64

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        format: ClipboardFormat,
        data: Data,
        sequenceNumber: UInt64 = 0
    ) {
        self.timestamp = timestamp
        self.format = format
        self.data = data
        self.sequenceNumber = sequenceNumber
    }
}

/// Heartbeat to indicate agent is alive.
public struct HeartbeatMessage: GuestMessage {
    public let timestamp: Int64
    public let trackedWindowCount: Int32
    public let uptimeMs: Int64
    public let cpuUsagePercent: Float
    public let memoryUsageBytes: Int64

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        trackedWindowCount: Int32 = 0,
        uptimeMs: Int64 = 0,
        cpuUsagePercent: Float = 0,
        memoryUsageBytes: Int64 = 0
    ) {
        self.timestamp = timestamp
        self.trackedWindowCount = trackedWindowCount
        self.uptimeMs = uptimeMs
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsageBytes = memoryUsageBytes
    }
}

/// Error notification from guest.
public struct GuestErrorMessage: GuestMessage {
    public let timestamp: Int64
    public let code: String
    public let message: String
    public let relatedMessageId: UInt32?

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        code: String,
        message: String,
        relatedMessageId: UInt32? = nil
    ) {
        self.timestamp = timestamp
        self.code = code
        self.message = message
        self.relatedMessageId = relatedMessageId
    }
}

/// Acknowledgement of a host message.
public struct AckMessage: GuestMessage {
    public let timestamp: Int64
    public let messageId: UInt32
    public let success: Bool
    public let errorMessage: String?

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        messageId: UInt32,
        success: Bool = true,
        errorMessage: String? = nil
    ) {
        self.timestamp = timestamp
        self.messageId = messageId
        self.success = success
        self.errorMessage = errorMessage
    }
}

// MARK: - Session Messages

/// Session state in the guest agent.
public enum SpiceSessionState: String, Codable {
    case starting
    case active
    case idle
    case exited
}

/// Individual session information from the guest.
public struct SpiceSessionInfo: Codable, Hashable {
    public let sessionId: String
    public let processId: Int32
    public let executablePath: String
    public let windowTitle: String?
    public let startTimeMs: Int64
    public let lastActivityMs: Int64
    public let state: SpiceSessionState
    public let windowCount: Int32

    public init(
        sessionId: String,
        processId: Int32,
        executablePath: String,
        windowTitle: String?,
        startTimeMs: Int64,
        lastActivityMs: Int64,
        state: SpiceSessionState,
        windowCount: Int32
    ) {
        self.sessionId = sessionId
        self.processId = processId
        self.executablePath = executablePath
        self.windowTitle = windowTitle
        self.startTimeMs = startTimeMs
        self.lastActivityMs = lastActivityMs
        self.state = state
        self.windowCount = windowCount
    }

    /// Converts this Spice session info to the shared GuestSession type.
    public func toGuestSession() -> WinRunShared.GuestSession {
        WinRunShared.GuestSession(
            id: sessionId,
            windowsPath: executablePath,
            windowTitle: windowTitle,
            processId: Int(processId),
            startedAt: Date(timeIntervalSince1970: Double(startTimeMs) / 1000.0)
        )
    }
}

/// Response message containing the list of active sessions.
public struct SessionListMessage: GuestMessage {
    public let timestamp: Int64
    public let messageId: UInt32
    public let sessions: [SpiceSessionInfo]

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        messageId: UInt32,
        sessions: [SpiceSessionInfo]
    ) {
        self.timestamp = timestamp
        self.messageId = messageId
        self.sessions = sessions
    }

    /// Converts to GuestSessionList for XPC responses.
    public func toGuestSessionList() -> WinRunShared.GuestSessionList {
        WinRunShared.GuestSessionList(sessions: sessions.map { $0.toGuestSession() })
    }
}

// MARK: - Provisioning Messages

/// Phase of post-install provisioning running in the guest.
public enum GuestProvisioningPhase: String, Codable, Sendable {
    /// Installing VirtIO drivers.
    case drivers

    /// Installing WinRun Agent.
    case agent

    /// Optimizing Windows (removing bloat, disabling services).
    case optimize

    /// Finalizing configuration before shutdown.
    case finalize

    /// Provisioning complete.
    case complete

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
public struct ProvisionProgressMessage: GuestMessage {
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
public struct ProvisionErrorMessage: GuestMessage {
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
public struct ProvisionCompleteMessage: GuestMessage {
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
