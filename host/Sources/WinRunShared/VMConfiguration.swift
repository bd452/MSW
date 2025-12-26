import Foundation

// MARK: - VM Resources

public struct VMResources: Codable, Hashable {
    public let cpuCount: Int
    public let memorySizeGB: Int

    public init(cpuCount: Int = 4, memorySizeGB: Int = 4) {
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }
}

public extension VMResources {
    static let supportedCPURange = 2...32
    static let supportedMemoryRangeGB = 4...64

    func validate() throws {
        if !VMResources.supportedCPURange.contains(cpuCount) {
            throw VMConfigurationValidationError.cpuCountOutOfRange(
                actual: cpuCount,
                allowed: VMResources.supportedCPURange
            )
        }
        if !VMResources.supportedMemoryRangeGB.contains(memorySizeGB) {
            throw VMConfigurationValidationError.memoryOutOfRange(
                actual: memorySizeGB,
                allowed: VMResources.supportedMemoryRangeGB
            )
        }
    }
}

// MARK: - VM Disk Configuration

public struct VMDiskConfiguration: Codable, Hashable {
    public var imagePath: URL
    public var sizeGB: Int

    public init(
        imagePath: URL = VMDiskConfiguration.defaultImagePath,
        sizeGB: Int = 64
    ) {
        self.imagePath = imagePath
        self.sizeGB = sizeGB
    }

    public static var defaultImagePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/windows.img")
    }
}

public extension VMDiskConfiguration {
    private var minimumSizeGB: Int { 32 }

    func validate(fileManager: FileManager = .default) throws {
        guard sizeGB >= minimumSizeGB else {
            throw VMConfigurationValidationError.diskSizeTooSmall(actual: sizeGB)
        }

        let directoryURL = imagePath.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                throw VMConfigurationValidationError.diskDirectoryUnavailable(directoryURL)
            }
        } else if !isDirectory.boolValue {
            throw VMConfigurationValidationError.diskDirectoryUnavailable(directoryURL)
        }

        var isImageDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: imagePath.path, isDirectory: &isImageDirectory) else {
            throw VMConfigurationValidationError.diskImageMissing(imagePath)
        }

        if isImageDirectory.boolValue {
            throw VMConfigurationValidationError.diskImageIsDirectory(imagePath)
        }
    }
}

// MARK: - VM Network Configuration

public enum VMNetworkAttachmentMode: String, Codable, CaseIterable, Hashable {
    case nat
    case bridged
}

public struct VMNetworkConfiguration: Codable, Hashable {
    public var mode: VMNetworkAttachmentMode
    public var interfaceIdentifier: String?
    public var macAddress: String?

    public init(
        mode: VMNetworkAttachmentMode = .nat,
        interfaceIdentifier: String? = nil,
        macAddress: String? = nil
    ) {
        self.mode = mode
        self.interfaceIdentifier = interfaceIdentifier
        self.macAddress = macAddress
    }
}

public extension VMNetworkConfiguration {
    func validate() throws {
        if mode == .bridged, interfaceIdentifier?.isEmpty ?? true {
            throw VMConfigurationValidationError.bridgedInterfaceNotSpecified
        }
    }
}

// MARK: - Frame Streaming Configuration

/// Configuration for guest-host frame streaming communication.
public struct FrameStreamingConfiguration: Codable, Hashable {
    /// Whether vsock is enabled for frame streaming.
    /// Vsock provides a direct communication channel between host and guest.
    public var vsockEnabled: Bool

    /// The vsock context ID (CID) for the guest.
    /// This is automatically assigned by Virtualization.framework when not specified.
    public var vsockCID: UInt32?

    /// Port number for the control channel on vsock.
    public var controlPort: UInt32

    /// Port number for frame data on vsock.
    public var frameDataPort: UInt32

    /// Whether to enable shared memory for zero-copy frame transfers.
    /// Shared memory provides lowest latency for frame data.
    public var sharedMemoryEnabled: Bool

    /// Size of the shared memory region in megabytes.
    /// Larger sizes can buffer more frames but use more memory.
    public var sharedMemorySizeMB: Int

    /// Whether to enable the Spice console port channel.
    public var spiceConsoleEnabled: Bool

    public init(
        vsockEnabled: Bool = true,
        vsockCID: UInt32? = nil,
        controlPort: UInt32 = 5900,
        frameDataPort: UInt32 = 5901,
        sharedMemoryEnabled: Bool = true,
        sharedMemorySizeMB: Int = 64,
        spiceConsoleEnabled: Bool = true
    ) {
        self.vsockEnabled = vsockEnabled
        self.vsockCID = vsockCID
        self.controlPort = controlPort
        self.frameDataPort = frameDataPort
        self.sharedMemoryEnabled = sharedMemoryEnabled
        self.sharedMemorySizeMB = sharedMemorySizeMB
        self.spiceConsoleEnabled = spiceConsoleEnabled
    }
}

public extension FrameStreamingConfiguration {
    /// Minimum shared memory size in MB
    static let minimumSharedMemorySizeMB = 16

    /// Maximum shared memory size in MB (256 MB)
    static let maximumSharedMemorySizeMB = 256

    /// Valid port range for vsock
    static let validPortRange: ClosedRange<UInt32> = 1...65535

    func validate() throws {
        if sharedMemoryEnabled {
            if sharedMemorySizeMB < Self.minimumSharedMemorySizeMB {
                throw VMConfigurationValidationError.sharedMemoryTooSmall(
                    actual: sharedMemorySizeMB,
                    minimum: Self.minimumSharedMemorySizeMB
                )
            }
            if sharedMemorySizeMB > Self.maximumSharedMemorySizeMB {
                throw VMConfigurationValidationError.sharedMemoryTooLarge(
                    actual: sharedMemorySizeMB,
                    maximum: Self.maximumSharedMemorySizeMB
                )
            }
        }

        if vsockEnabled {
            if !Self.validPortRange.contains(controlPort) {
                throw VMConfigurationValidationError.invalidVsockPort(controlPort)
            }
            if !Self.validPortRange.contains(frameDataPort) {
                throw VMConfigurationValidationError.invalidVsockPort(frameDataPort)
            }
            if controlPort == frameDataPort {
                throw VMConfigurationValidationError.duplicateVsockPort(controlPort)
            }
        }
    }
}

// MARK: - VM Configuration

public struct VMConfiguration: Codable, Hashable {
    public var resources: VMResources
    public var disk: VMDiskConfiguration
    public var network: VMNetworkConfiguration
    public var frameStreaming: FrameStreamingConfiguration
    public var suspendOnIdleAfterSeconds: TimeInterval

    public init(
        resources: VMResources = VMResources(),
        disk: VMDiskConfiguration = VMDiskConfiguration(),
        network: VMNetworkConfiguration = VMNetworkConfiguration(),
        frameStreaming: FrameStreamingConfiguration = FrameStreamingConfiguration(),
        suspendOnIdleAfterSeconds: TimeInterval = 300
    ) {
        self.resources = resources
        self.disk = disk
        self.network = network
        self.frameStreaming = frameStreaming
        self.suspendOnIdleAfterSeconds = suspendOnIdleAfterSeconds
    }

    public var diskImagePath: URL {
        get { disk.imagePath }
        set { disk.imagePath = newValue }
    }
}

public extension VMConfiguration {
    func validate(fileManager: FileManager = .default) throws {
        try resources.validate()
        try disk.validate(fileManager: fileManager)
        try network.validate()
        try frameStreaming.validate()
    }
}

// MARK: - VM Configuration Validation Errors

public enum VMConfigurationValidationError: Error, CustomStringConvertible {
    case cpuCountOutOfRange(actual: Int, allowed: ClosedRange<Int>)
    case memoryOutOfRange(actual: Int, allowed: ClosedRange<Int>)
    case diskDirectoryUnavailable(URL)
    case diskImageMissing(URL)
    case diskImageIsDirectory(URL)
    case diskSizeTooSmall(actual: Int)
    case bridgedInterfaceNotSpecified
    case bridgedInterfaceUnavailable(String)
    case sharedMemoryTooSmall(actual: Int, minimum: Int)
    case sharedMemoryTooLarge(actual: Int, maximum: Int)
    case invalidVsockPort(UInt32)
    case duplicateVsockPort(UInt32)

    public var description: String {
        switch self {
        case .cpuCountOutOfRange(let actual, let allowed):
            return "CPU count \(actual) is outside of supported range \(allowed.lowerBound)-\(allowed.upperBound)."
        case .memoryOutOfRange(let actual, let allowed):
            return "Memory \(actual)GB falls outside of supported range \(allowed.lowerBound)-\(allowed.upperBound)GB."
        case .diskDirectoryUnavailable(let url):
            return "Disk directory \(url.path) is unavailable or cannot be created."
        case .diskImageMissing(let url):
            return "Disk image \(url.path) is missing. Run winrun init to provision Windows."
        case .diskImageIsDirectory(let url):
            return "Disk image path \(url.path) points to a directory, expected file."
        case .diskSizeTooSmall(let actual):
            return "Configured disk size \(actual)GB is below the minimum of 32GB."
        case .bridgedInterfaceNotSpecified:
            return "Bridged networking requires an interface identifier."
        case .bridgedInterfaceUnavailable(let identifier):
            return "Bridged interface \(identifier) was not found on this host."
        case .sharedMemoryTooSmall(let actual, let minimum):
            return "Shared memory size \(actual)MB is below the minimum of \(minimum)MB."
        case .sharedMemoryTooLarge(let actual, let maximum):
            return "Shared memory size \(actual)MB exceeds the maximum of \(maximum)MB."
        case .invalidVsockPort(let port):
            return "Vsock port \(port) is outside the valid range (1-65535)."
        case .duplicateVsockPort(let port):
            return "Vsock port \(port) is used for both control and frame data channels."
        }
    }
}

// MARK: - VM State

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

public struct VMMetricsSnapshot: Codable, CustomStringConvertible {
    public let event: String
    public let uptimeSeconds: TimeInterval
    public let activeSessions: Int
    public let totalSessions: Int
    public let bootCount: Int
    public let suspendCount: Int

    public init(
        event: String,
        uptimeSeconds: TimeInterval,
        activeSessions: Int,
        totalSessions: Int,
        bootCount: Int,
        suspendCount: Int
    ) {
        self.event = event
        self.uptimeSeconds = uptimeSeconds
        self.activeSessions = activeSessions
        self.totalSessions = totalSessions
        self.bootCount = bootCount
        self.suspendCount = suspendCount
    }

    public var description: String {
        let uptimeString = String(format: "%.2fs", uptimeSeconds)
        return "event=\(event) uptime=\(uptimeString) activeSessions=\(activeSessions) totalSessions=\(totalSessions) boots=\(bootCount) suspends=\(suspendCount)"
    }
}

// MARK: - Program Launch

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

// MARK: - Guest Session

/// Represents an active program session running in the guest VM
public struct GuestSession: Codable, Hashable, Identifiable {
    public let id: String
    public let windowsPath: String
    public let windowTitle: String?
    public let processId: Int
    public let startedAt: Date

    public init(id: String, windowsPath: String, windowTitle: String?, processId: Int, startedAt: Date) {
        self.id = id
        self.windowsPath = windowsPath
        self.windowTitle = windowTitle
        self.processId = processId
        self.startedAt = startedAt
    }
}

public struct GuestSessionList: Codable {
    public let sessions: [GuestSession]

    public init(sessions: [GuestSession]) {
        self.sessions = sessions
    }
}

// MARK: - Windows Shortcut

/// Represents a Windows shortcut (.lnk) detected in the guest VM
public struct WindowsShortcut: Codable, Hashable, Identifiable {
    public var id: String { shortcutPath }
    public let shortcutPath: String
    public let targetPath: String
    public let displayName: String
    public let iconPath: String?
    public let arguments: String?
    public let detectedAt: Date

    public init(
        shortcutPath: String,
        targetPath: String,
        displayName: String,
        iconPath: String? = nil,
        arguments: String? = nil,
        detectedAt: Date = Date()
    ) {
        self.shortcutPath = shortcutPath
        self.targetPath = targetPath
        self.displayName = displayName
        self.iconPath = iconPath
        self.arguments = arguments
        self.detectedAt = detectedAt
    }
}

public struct WindowsShortcutList: Codable {
    public let shortcuts: [WindowsShortcut]

    public init(shortcuts: [WindowsShortcut]) {
        self.shortcuts = shortcuts
    }
}

public struct ShortcutSyncResult: Codable {
    public let created: Int
    public let skipped: Int
    public let failed: Int
    public let launcherPaths: [String]

    public init(created: Int, skipped: Int, failed: Int, launcherPaths: [String]) {
        self.created = created
        self.skipped = skipped
        self.failed = failed
        self.launcherPaths = launcherPaths
    }
}
