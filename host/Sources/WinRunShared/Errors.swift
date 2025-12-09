import Foundation

// MARK: - Error Domain

/// Categorizes WinRun errors by subsystem for logging and filtering.
public enum WinRunErrorDomain: String, CaseIterable, Codable {
    case virtualMachine = "vm"
    case configuration = "config"
    case spice = "spice"
    case xpc = "xpc"
    case launcher = "launcher"
    case general = "general"

    public var displayName: String {
        switch self {
        case .virtualMachine: return "Virtual Machine"
        case .configuration: return "Configuration"
        case .spice: return "Spice Connection"
        case .xpc: return "IPC"
        case .launcher: return "Launcher"
        case .general: return "General"
        }
    }
}

// MARK: - WinRun Error

/// Unified error type for WinRun operations with localization support.
///
/// `WinRunError` conforms to `LocalizedError` to provide user-friendly descriptions
/// and recovery suggestions. Use `domain` to categorize errors for logging.
///
/// ## Example
/// ```swift
/// do {
///     try await vmController.start()
/// } catch let error as WinRunError {
///     print(error.localizedDescription)      // User-friendly message
///     print(error.recoverySuggestion ?? "")  // How to fix it
///     logger.error("[\(error.domain.rawValue)] \(error.technicalDescription)")
/// }
/// ```
public enum WinRunError: Error, LocalizedError, CustomStringConvertible {
    // MARK: - Virtual Machine Errors

    /// VM has not completed initial setup/provisioning.
    case vmNotInitialized

    /// VM is already in the stopped state.
    case vmAlreadyStopped

    /// Timed out waiting for VM operation to complete.
    case vmOperationTimeout(operation: String, timeoutSeconds: TimeInterval)

    /// VM state cannot be saved or restored.
    case vmSnapshotFailed(reason: String)

    /// Virtualization.framework is unavailable or incompatible.
    case virtualizationUnavailable(reason: String)

    // MARK: - Configuration Errors

    /// Configuration file could not be read.
    case configReadFailed(path: String, underlying: Error?)

    /// Configuration file could not be written.
    case configWriteFailed(path: String, underlying: Error?)

    /// Configuration file has invalid format or content.
    case configInvalid(reason: String)

    /// Configuration schema version is not supported.
    case configSchemaUnsupported(found: Int, supported: Int)

    /// Required configuration value is missing.
    case configMissingValue(key: String)

    // MARK: - Spice Connection Errors

    /// Failed to establish Spice connection.
    case spiceConnectionFailed(reason: String)

    /// Spice connection was unexpectedly closed.
    case spiceDisconnected(reason: String)

    /// Shared memory transport is unavailable.
    case spiceSharedMemoryUnavailable(reason: String)

    /// Spice authentication failed.
    case spiceAuthenticationFailed(reason: String)

    // MARK: - IPC/XPC Errors

    /// Unable to reach the WinRun daemon.
    case daemonUnreachable

    /// XPC connection was rejected.
    case xpcConnectionRejected(reason: String)

    /// XPC request was rate-limited.
    case xpcThrottled(retryAfterSeconds: TimeInterval)

    /// XPC caller is not authorized.
    case xpcUnauthorized(reason: String)

    // MARK: - Program Launch Errors

    /// Failed to launch a Windows program.
    case launchFailed(program: String, reason: String)

    /// Provided executable path is invalid or inaccessible.
    case invalidExecutable(path: String)

    /// Windows program exited with an error.
    case programExitedWithError(program: String, exitCode: Int)

    // MARK: - Launcher Errors

    /// Launcher bundle already exists.
    case launcherAlreadyExists(path: String)

    /// Failed to create launcher bundle.
    case launcherCreationFailed(name: String, reason: String)

    /// Icon file not found or invalid.
    case launcherIconMissing(path: String)

    // MARK: - General Errors

    /// Operation was cancelled.
    case cancelled

    /// An unexpected internal error occurred.
    case internalError(message: String)

    /// Feature is not available on this platform or version.
    case notSupported(feature: String)

    // MARK: - Error Domain

    /// The error domain for categorization and logging.
    public var domain: WinRunErrorDomain {
        switch self {
        case .vmNotInitialized, .vmAlreadyStopped, .vmOperationTimeout,
             .vmSnapshotFailed, .virtualizationUnavailable:
            return .virtualMachine
        case .configReadFailed, .configWriteFailed, .configInvalid,
             .configSchemaUnsupported, .configMissingValue:
            return .configuration
        case .spiceConnectionFailed, .spiceDisconnected,
             .spiceSharedMemoryUnavailable, .spiceAuthenticationFailed:
            return .spice
        case .daemonUnreachable, .xpcConnectionRejected, .xpcThrottled, .xpcUnauthorized:
            return .xpc
        case .launchFailed, .invalidExecutable, .programExitedWithError:
            return .general
        case .launcherAlreadyExists, .launcherCreationFailed, .launcherIconMissing:
            return .launcher
        case .cancelled, .internalError, .notSupported:
            return .general
        }
    }

    // MARK: - Localized Error Protocol

    public var errorDescription: String? {
        switch self {
        // VM errors
        case .vmNotInitialized:
            return "Windows VM is not ready"
        case .vmAlreadyStopped:
            return "Windows VM is already stopped"
        case .vmOperationTimeout(let operation, _):
            return "VM \(operation) timed out"
        case .vmSnapshotFailed:
            return "Failed to save or restore VM state"
        case .virtualizationUnavailable:
            return "Virtualization is not available"

        // Config errors
        case .configReadFailed:
            return "Could not read configuration"
        case .configWriteFailed:
            return "Could not save configuration"
        case .configInvalid:
            return "Configuration is invalid"
        case .configSchemaUnsupported:
            return "Configuration file is from an incompatible version"
        case .configMissingValue(let key):
            return "Missing required setting: \(key)"

        // Spice errors
        case .spiceConnectionFailed:
            return "Could not connect to Windows display"
        case .spiceDisconnected:
            return "Connection to Windows was lost"
        case .spiceSharedMemoryUnavailable:
            return "High-performance display connection unavailable"
        case .spiceAuthenticationFailed:
            return "Display authentication failed"

        // XPC errors
        case .daemonUnreachable:
            return "WinRun service is not running"
        case .xpcConnectionRejected:
            return "Connection to WinRun service was rejected"
        case .xpcThrottled(let seconds):
            return "Too many requests. Try again in \(Int(seconds)) seconds"
        case .xpcUnauthorized:
            return "Not authorized to perform this action"

        // Launch errors
        case .launchFailed(let program, _):
            return "Failed to launch \(program)"
        case .invalidExecutable(let path):
            return "Invalid executable: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .programExitedWithError(let program, let exitCode):
            return "\(program) exited with error code \(exitCode)"

        // Launcher errors
        case .launcherAlreadyExists:
            return "Launcher already exists"
        case .launcherCreationFailed(let name, _):
            return "Could not create launcher for \(name)"
        case .launcherIconMissing:
            return "Icon file not found"

        // General errors
        case .cancelled:
            return "Operation was cancelled"
        case .internalError:
            return "An internal error occurred"
        case .notSupported(let feature):
            return "\(feature) is not supported"
        }
    }

    public var failureReason: String? {
        switch self {
        case .vmNotInitialized:
            return "The Windows virtual machine has not completed initial provisioning."
        case .vmAlreadyStopped:
            return "The VM is already in a stopped state."
        case .vmOperationTimeout(let operation, let timeout):
            return "The \(operation) operation did not complete within \(Int(timeout)) seconds."
        case .vmSnapshotFailed(let reason):
            return reason
        case .virtualizationUnavailable(let reason):
            return reason

        case .configReadFailed(let path, let underlying):
            if let err = underlying {
                return "Could not read \(path): \(err.localizedDescription)"
            }
            return "Could not read configuration at \(path)."
        case .configWriteFailed(let path, let underlying):
            if let err = underlying {
                return "Could not write to \(path): \(err.localizedDescription)"
            }
            return "Could not save configuration to \(path)."
        case .configInvalid(let reason):
            return reason
        case .configSchemaUnsupported(let found, let supported):
            return "Config version \(found) is newer than the maximum supported version \(supported)."
        case .configMissingValue(let key):
            return "The required setting '\(key)' is not configured."

        case .spiceConnectionFailed(let reason):
            return reason
        case .spiceDisconnected(let reason):
            return reason
        case .spiceSharedMemoryUnavailable(let reason):
            return reason
        case .spiceAuthenticationFailed(let reason):
            return reason

        case .daemonUnreachable:
            return "The winrund daemon is not running or not accepting connections."
        case .xpcConnectionRejected(let reason):
            return reason
        case .xpcThrottled(let seconds):
            return "Rate limit exceeded. Retry after \(String(format: "%.1f", seconds)) seconds."
        case .xpcUnauthorized(let reason):
            return reason

        case .launchFailed(_, let reason):
            return reason
        case .invalidExecutable(let path):
            return "The path '\(path)' does not point to a valid executable file."
        case .programExitedWithError(_, let exitCode):
            return "The program terminated with exit code \(exitCode)."

        case .launcherAlreadyExists(let path):
            return "A launcher bundle already exists at \(path)."
        case .launcherCreationFailed(_, let reason):
            return reason
        case .launcherIconMissing(let path):
            return "Icon file not found at \(path)."

        case .cancelled:
            return "The operation was cancelled by the user or system."
        case .internalError(let message):
            return message
        case .notSupported(let feature):
            return "The feature '\(feature)' is not available on this system or version."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .vmNotInitialized:
            return "Run 'winrun init' to set up the Windows virtual machine."
        case .vmAlreadyStopped:
            return "Start the VM with 'winrun vm start' before performing this operation."
        case .vmOperationTimeout:
            return "Check system resources and try again. If the problem persists, restart WinRun."
        case .vmSnapshotFailed:
            return "Ensure sufficient disk space is available and try again."
        case .virtualizationUnavailable:
            return "WinRun requires macOS 13 or later on Apple Silicon or Intel hardware with VT-x support."

        case .configReadFailed, .configWriteFailed:
            return "Check file permissions and disk space, then try again."
        case .configInvalid:
            return "Delete the configuration file and run 'winrun init' to create a new one."
        case .configSchemaUnsupported:
            return "Update WinRun to the latest version to read this configuration."
        case .configMissingValue:
            return "Add the missing value to your configuration or run 'winrun init' to reset defaults."

        case .spiceConnectionFailed, .spiceDisconnected:
            return "Ensure the Windows VM is running and try reconnecting."
        case .spiceSharedMemoryUnavailable:
            return "The system will fall back to TCP transport. Performance may be reduced."
        case .spiceAuthenticationFailed:
            return "Restart the Windows VM and try again."

        case .daemonUnreachable:
            return "Start the WinRun service with 'sudo launchctl load /Library/LaunchDaemons/com.winrun.daemon.plist'."
        case .xpcConnectionRejected:
            return "Ensure WinRun is properly installed and the current user has permission to use it."
        case .xpcThrottled:
            return "Wait a moment before retrying your request."
        case .xpcUnauthorized:
            return "Check that your user account has permission to use WinRun."

        case .launchFailed:
            return "Verify the program path is correct and the Windows VM is running."
        case .invalidExecutable:
            return "Check that the file exists and is a valid Windows executable (.exe)."
        case .programExitedWithError:
            return "Check the program's documentation for information about this error code."

        case .launcherAlreadyExists:
            return "Use --force to overwrite the existing launcher, or choose a different name."
        case .launcherCreationFailed:
            return "Check that you have write permission to the destination directory."
        case .launcherIconMissing:
            return "Provide a valid .icns icon file or omit the icon option to use the default."

        case .cancelled:
            return nil
        case .internalError:
            return "Please report this issue at https://github.com/winrun/winrun/issues"
        case .notSupported:
            return "Check the WinRun documentation for system requirements and supported features."
        }
    }

    // MARK: - Custom String Convertible

    /// Technical description suitable for logging (includes all details).
    public var description: String {
        technicalDescription
    }

    /// Technical description with full error details for logging and debugging.
    public var technicalDescription: String {
        let base: String
        switch self {
        case .vmNotInitialized:
            base = "VM not initialized"
        case .vmAlreadyStopped:
            base = "VM already stopped"
        case .vmOperationTimeout(let operation, let timeout):
            base = "VM \(operation) timeout after \(timeout)s"
        case .vmSnapshotFailed(let reason):
            base = "VM snapshot failed: \(reason)"
        case .virtualizationUnavailable(let reason):
            base = "Virtualization unavailable: \(reason)"

        case .configReadFailed(let path, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            base = "Config read failed at \(path)\(detail)"
        case .configWriteFailed(let path, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            base = "Config write failed at \(path)\(detail)"
        case .configInvalid(let reason):
            base = "Config invalid: \(reason)"
        case .configSchemaUnsupported(let found, let supported):
            base = "Config schema v\(found) unsupported (max v\(supported))"
        case .configMissingValue(let key):
            base = "Config missing key: \(key)"

        case .spiceConnectionFailed(let reason):
            base = "Spice connection failed: \(reason)"
        case .spiceDisconnected(let reason):
            base = "Spice disconnected: \(reason)"
        case .spiceSharedMemoryUnavailable(let reason):
            base = "Spice shared memory unavailable: \(reason)"
        case .spiceAuthenticationFailed(let reason):
            base = "Spice auth failed: \(reason)"

        case .daemonUnreachable:
            base = "Daemon unreachable"
        case .xpcConnectionRejected(let reason):
            base = "XPC connection rejected: \(reason)"
        case .xpcThrottled(let seconds):
            base = "XPC throttled, retry after \(String(format: "%.1f", seconds))s"
        case .xpcUnauthorized(let reason):
            base = "XPC unauthorized: \(reason)"

        case .launchFailed(let program, let reason):
            base = "Launch failed for '\(program)': \(reason)"
        case .invalidExecutable(let path):
            base = "Invalid executable: \(path)"
        case .programExitedWithError(let program, let exitCode):
            base = "Program '\(program)' exited with code \(exitCode)"

        case .launcherAlreadyExists(let path):
            base = "Launcher exists: \(path)"
        case .launcherCreationFailed(let name, let reason):
            base = "Launcher creation failed for '\(name)': \(reason)"
        case .launcherIconMissing(let path):
            base = "Launcher icon missing: \(path)"

        case .cancelled:
            base = "Operation cancelled"
        case .internalError(let message):
            base = "Internal error: \(message)"
        case .notSupported(let feature):
            base = "Not supported: \(feature)"
        }
        return "[\(domain.rawValue)] \(base)"
    }
}

// MARK: - Error Wrapping Helpers

public extension WinRunError {
    /// Wraps an arbitrary error as an internal WinRunError.
    static func wrap(_ error: Error, context: String? = nil) -> WinRunError {
        if let winRunError = error as? WinRunError {
            return winRunError
        }
        let message = context.map { "\($0): \(error.localizedDescription)" }
            ?? error.localizedDescription
        return .internalError(message: message)
    }
}

// MARK: - Error Code (for bridging)

public extension WinRunError {
    /// Integer error code for bridging to C APIs or XPC.
    var code: Int {
        switch self {
        case .vmNotInitialized: return 1001
        case .vmAlreadyStopped: return 1002
        case .vmOperationTimeout: return 1003
        case .vmSnapshotFailed: return 1004
        case .virtualizationUnavailable: return 1005

        case .configReadFailed: return 2001
        case .configWriteFailed: return 2002
        case .configInvalid: return 2003
        case .configSchemaUnsupported: return 2004
        case .configMissingValue: return 2005

        case .spiceConnectionFailed: return 3001
        case .spiceDisconnected: return 3002
        case .spiceSharedMemoryUnavailable: return 3003
        case .spiceAuthenticationFailed: return 3004

        case .daemonUnreachable: return 4001
        case .xpcConnectionRejected: return 4002
        case .xpcThrottled: return 4003
        case .xpcUnauthorized: return 4004

        case .launchFailed: return 5001
        case .invalidExecutable: return 5002
        case .programExitedWithError: return 5003

        case .launcherAlreadyExists: return 6001
        case .launcherCreationFailed: return 6002
        case .launcherIconMissing: return 6003

        case .cancelled: return 9001
        case .internalError: return 9002
        case .notSupported: return 9003
        }
    }
}

// MARK: - Equatable

extension WinRunError: Equatable {
    public static func == (lhs: WinRunError, rhs: WinRunError) -> Bool {
        // Compare by code and domain for equality (ignoring associated value details)
        lhs.code == rhs.code
    }
}

