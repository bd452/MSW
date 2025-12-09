import Foundation

// MARK: - WinRun Errors

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

