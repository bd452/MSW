import Foundation

// MARK: - Logger Protocol

public protocol Logger {
    func debug(_ message: String)
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

// MARK: - Standard Logger

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

