import Foundation

public struct VMResources: Codable, Hashable {
    public let cpuCount: Int
    public let memorySizeGB: Int

    public init(cpuCount: Int = 4, memorySizeGB: Int = 4) {
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }
}

public struct VMConfiguration: Codable, Hashable {
    public var resources: VMResources
    public var diskImagePath: URL
    public var suspendOnIdleAfterSeconds: TimeInterval

    public init(
        resources: VMResources = VMResources(),
        diskImagePath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/windows.img"),
        suspendOnIdleAfterSeconds: TimeInterval = 300
    ) {
        self.resources = resources
        self.diskImagePath = diskImagePath
        self.suspendOnIdleAfterSeconds = suspendOnIdleAfterSeconds
    }
}

public enum WinRunError: Error, CustomStringConvertible {
    case vmNotInitialized
    case launchFailed(reason: String)
    case invalidExecutable
    case ipcFailure

    public var description: String {
        switch self {
        case .vmNotInitialized:
            return "Windows VM has not completed initial provisioning."
        case .launchFailed(let reason):
            return "Failed to launch program: \(reason)"
        case .invalidExecutable:
            return "Provided executable path is invalid or missing."
        case .ipcFailure:
            return "Unable to reach winrund daemon. Is it running?"
        }
    }
}

public struct ProgramLaunchRequest: Codable, Hashable {
    public let windowsPath: String
    public let arguments: [String]
    public let workingDirectory: String?

    public init(windowsPath: String, arguments: [String] = [], workingDirectory: String? = nil) {
        self.windowsPath = windowsPath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public enum VMStatus: String, Codable {
    case stopped
    case starting
    case running
    case suspending
    case suspended
    case stopping
}

public struct VMState: Codable {
    public var status: VMStatus
    public var uptime: TimeInterval
    public var activeSessions: Int

    public init(status: VMStatus, uptime: TimeInterval, activeSessions: Int) {
        self.status = status
        self.uptime = uptime
        self.activeSessions = activeSessions
    }
}

public struct SpiceStreamMetrics: Codable, Hashable {
    public var framesReceived: Int
    public var metadataUpdates: Int
    public var reconnectAttempts: Int
    public var lastErrorDescription: String?

    public init(
        framesReceived: Int = 0,
        metadataUpdates: Int = 0,
        reconnectAttempts: Int = 0,
        lastErrorDescription: String? = nil
    ) {
        self.framesReceived = framesReceived
        self.metadataUpdates = metadataUpdates
        self.reconnectAttempts = reconnectAttempts
        self.lastErrorDescription = lastErrorDescription
    }
}

public protocol Logger {
    func debug(_ message: String)
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

public struct StandardLogger: Logger {
    private let subsystem: String

    public init(subsystem: String) {
        self.subsystem = subsystem
    }

    public func debug(_ message: String) {
        print("[DEBUG][\(subsystem)] \(message)")
    }

    public func info(_ message: String) {
        print("[INFO][\(subsystem)] \(message)")
    }

    public func warn(_ message: String) {
        print("[WARN][\(subsystem)] \(message)")
    }

    public func error(_ message: String) {
        print("[ERROR][\(subsystem)] \(message)")
    }
}
