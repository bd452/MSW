import Foundation
import os.log

// MARK: - Log Level

/// Log severity levels ordered by verbosity (debug is most verbose)
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var name: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        }
    }
}

// MARK: - Log Metadata

/// Structured key-value metadata attached to log entries
public typealias LogMetadata = [String: LogMetadataValue]

/// Values that can be attached as log metadata
public enum LogMetadataValue: Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([LogMetadataValue])
    case dictionary([String: LogMetadataValue])

    public var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return String(v)
        case .array(let v): return v.map(\.description).joined(separator: ", ")
        case .dictionary(let v): return v.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
    }
}

// ExpressibleBy conformances for ergonomic metadata construction
extension LogMetadataValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension LogMetadataValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension LogMetadataValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension LogMetadataValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Logger Protocol

/// Protocol for logging implementations supporting structured metadata
public protocol Logger: Sendable {
    /// Log a message at the specified level with optional metadata
    func log(
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        file: String,
        function: String,
        line: UInt
    )
}

// MARK: - Logger Convenience Methods

extension Logger {
    public func debug(
        _ message: String,
        metadata: LogMetadata? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .debug, message: message, metadata: metadata, file: file, function: function,
            line: line)
    }

    public func info(
        _ message: String,
        metadata: LogMetadata? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .info, message: message, metadata: metadata, file: file, function: function,
            line: line)
    }

    public func warn(
        _ message: String,
        metadata: LogMetadata? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .warn, message: message, metadata: metadata, file: file, function: function,
            line: line)
    }

    public func error(
        _ message: String,
        metadata: LogMetadata? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        log(
            level: .error, message: message, metadata: metadata, file: file, function: function,
            line: line)
    }
}

// MARK: - OS Log Logger

/// Logger that writes to Apple's unified logging system (os_log)
public struct OSLogLogger: Logger {
    private let osLog: OSLog
    private let minimumLevel: LogLevel

    /// Creates an OSLogLogger
    /// - Parameters:
    ///   - subsystem: Bundle identifier or subsystem name (e.g., "com.winrun.daemon")
    ///   - category: Log category for filtering (e.g., "vm", "spice", "xpc")
    ///   - minimumLevel: Minimum level to log (messages below this are ignored)
    public init(subsystem: String, category: String, minimumLevel: LogLevel = .debug) {
        self.osLog = OSLog(subsystem: subsystem, category: category)
        self.minimumLevel = minimumLevel
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= minimumLevel else { return }

        let formattedMessage: String
        if let metadata = metadata, !metadata.isEmpty {
            let metadataString = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            formattedMessage = "\(message) [\(metadataString)]"
        } else {
            formattedMessage = message
        }

        os_log("%{public}@", log: osLog, type: level.osLogType, formattedMessage)
    }
}

// MARK: - File Logger

/// Logger that writes to a file on disk with optional rotation
public final class FileLogger: Logger, @unchecked Sendable {
    private let fileURL: URL
    private let minimumLevel: LogLevel
    private let maxFileSizeBytes: UInt64
    private let dateFormatter: DateFormatter
    private let queue: DispatchQueue
    private var fileHandle: FileHandle?

    /// Creates a FileLogger
    /// - Parameters:
    ///   - fileURL: Path to the log file
    ///   - minimumLevel: Minimum level to log
    ///   - maxFileSizeBytes: Maximum file size before rotation (default 10MB)
    public init(
        fileURL: URL, minimumLevel: LogLevel = .debug, maxFileSizeBytes: UInt64 = 10_000_000
    ) {
        self.fileURL = fileURL
        self.minimumLevel = minimumLevel
        self.maxFileSizeBytes = maxFileSizeBytes
        self.queue = DispatchQueue(label: "com.winrun.filelogger", qos: .utility)

        self.dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        queue.sync { self.openFile() }
    }

    deinit {
        queue.sync {
            try? fileHandle?.close()
        }
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= minimumLevel else { return }

        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent

        var logLine = "[\(timestamp)] [\(level.name)] [\(fileName):\(line)] \(message)"
        if let metadata = metadata, !metadata.isEmpty {
            let metadataString = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            logLine += " [\(metadataString)]"
        }
        logLine += "\n"

        queue.async { [weak self] in
            self?.write(logLine)
        }
    }

    private func openFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }

    private func write(_ line: String) {
        rotateIfNeeded()

        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    private func rotateIfNeeded() {
        guard let handle = fileHandle else { return }

        let currentSize = handle.offsetInFile
        guard currentSize >= maxFileSizeBytes else { return }

        try? handle.close()

        // Rotate: rename current file with timestamp
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let rotatedURL = fileURL.deletingPathExtension()
            .appendingPathExtension("\(timestamp).log")

        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)

        openFile()

        // Clean up old logs (keep last 5)
        cleanupOldLogs()
    }

    private func cleanupOldLogs() {
        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent

        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }

        let rotatedLogs =
            files
            .filter { $0.lastPathComponent.hasPrefix(baseName) && $0 != fileURL }
            .sorted { url1, url2 in
                let date1 =
                    (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                let date2 =
                    (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                return date1 > date2
            }

        // Keep only the 5 most recent rotated logs
        for oldLog in rotatedLogs.dropFirst(5) {
            try? FileManager.default.removeItem(at: oldLog)
        }
    }

    /// Flushes any buffered log data to disk
    public func flush() {
        queue.sync {
            try? fileHandle?.synchronize()
        }
    }
}

// MARK: - Standard Logger (Print-based)

/// Simple print-based logger for development and testing
public struct StandardLogger: Logger {
    private let subsystem: String
    private let minimumLevel: LogLevel

    public init(subsystem: String, minimumLevel: LogLevel = .debug) {
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= minimumLevel else { return }

        var output = "[\(level.name)][\(subsystem)] \(message)"
        if let metadata = metadata, !metadata.isEmpty {
            let metadataString = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            output += " [\(metadataString)]"
        }
        print(output)
    }
}

// MARK: - Telemetry Logger

/// Protocol for telemetry/metrics collection
/// Implementations can send structured events to analytics services
public protocol TelemetryLogger: Sendable {
    /// Records a telemetry event with structured data
    func record(event: String, properties: [String: Any])

    /// Records a metric value
    func recordMetric(name: String, value: Double, unit: String?)

    /// Flushes any buffered telemetry data
    func flush()
}

/// No-op telemetry logger for when telemetry is disabled
public struct NoOpTelemetryLogger: TelemetryLogger {
    public init() {}

    public func record(event: String, properties: [String: Any]) {}
    public func recordMetric(name: String, value: Double, unit: String?) {}
    public func flush() {}
}

/// Logger wrapper that also sends high-level events to telemetry
public struct TelemetryAwareLogger: Logger {
    private let underlying: Logger
    private let telemetry: TelemetryLogger
    private let subsystem: String

    public init(underlying: Logger, telemetry: TelemetryLogger, subsystem: String) {
        self.underlying = underlying
        self.telemetry = telemetry
        self.subsystem = subsystem
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        file: String,
        function: String,
        line: UInt
    ) {
        underlying.log(
            level: level, message: message, metadata: metadata, file: file, function: function,
            line: line)

        // Send errors and warnings to telemetry
        if level >= .warn {
            var properties: [String: Any] = [
                "level": level.name,
                "message": message,
                "subsystem": subsystem,
                "file": (file as NSString).lastPathComponent,
                "line": line,
            ]
            if let metadata = metadata {
                for (key, value) in metadata {
                    properties["meta_\(key)"] = value.description
                }
            }
            telemetry.record(event: "log_\(level.name.lowercased())", properties: properties)
        }
    }
}

// MARK: - Composite Logger

/// Logger that dispatches to multiple underlying loggers
public struct CompositeLogger: Logger {
    private let loggers: [Logger]

    public init(_ loggers: [Logger]) {
        self.loggers = loggers
    }

    public init(_ loggers: Logger...) {
        self.loggers = loggers
    }

    public func log(
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        file: String,
        function: String,
        line: UInt
    ) {
        for logger in loggers {
            logger.log(
                level: level, message: message, metadata: metadata, file: file, function: function,
                line: line)
        }
    }
}

// MARK: - Logger Factory

/// Factory for creating pre-configured loggers for WinRun components
public enum LoggerFactory {
    /// Default log directory
    public static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WinRun")
    }

    /// Creates a logger for the daemon
    public static func daemon(fileLogging: Bool = true, minimumLevel: LogLevel = .info) -> Logger {
        createLogger(
            subsystem: "com.winrun.daemon",
            category: "daemon",
            logFileName: "winrund.log",
            fileLogging: fileLogging,
            minimumLevel: minimumLevel
        )
    }

    /// Creates a logger for the app
    public static func app(fileLogging: Bool = true, minimumLevel: LogLevel = .info) -> Logger {
        createLogger(
            subsystem: "com.winrun.app",
            category: "app",
            logFileName: "winrun-app.log",
            fileLogging: fileLogging,
            minimumLevel: minimumLevel
        )
    }

    /// Creates a logger for the CLI
    public static func cli(fileLogging: Bool = false, minimumLevel: LogLevel = .info) -> Logger {
        createLogger(
            subsystem: "com.winrun.cli",
            category: "cli",
            logFileName: "winrun-cli.log",
            fileLogging: fileLogging,
            minimumLevel: minimumLevel
        )
    }

    /// Creates a logger for VM operations
    public static func vm(fileLogging: Bool = true, minimumLevel: LogLevel = .info) -> Logger {
        createLogger(
            subsystem: "com.winrun.daemon",
            category: "vm",
            logFileName: "winrund.log",
            fileLogging: fileLogging,
            minimumLevel: minimumLevel
        )
    }

    /// Creates a logger for Spice operations
    public static func spice(fileLogging: Bool = true, minimumLevel: LogLevel = .info) -> Logger {
        createLogger(
            subsystem: "com.winrun.app",
            category: "spice",
            logFileName: "winrun-app.log",
            fileLogging: fileLogging,
            minimumLevel: minimumLevel
        )
    }

    private static func createLogger(
        subsystem: String,
        category: String,
        logFileName: String,
        fileLogging: Bool,
        minimumLevel: LogLevel
    ) -> Logger {
        let osLog = OSLogLogger(
            subsystem: subsystem, category: category, minimumLevel: minimumLevel)

        if fileLogging {
            let fileURL = defaultLogDirectory.appendingPathComponent(logFileName)
            let fileLog = FileLogger(fileURL: fileURL, minimumLevel: minimumLevel)
            return CompositeLogger(osLog, fileLog)
        }

        return osLog
    }
}
