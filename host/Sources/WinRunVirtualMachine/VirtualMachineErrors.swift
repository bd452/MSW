import Foundation

/// Errors that can occur during virtual machine lifecycle operations.
public enum VirtualMachineLifecycleError: Error, CustomStringConvertible {
    case startTimeout
    case invalidSnapshot(String)
    case virtualizationUnavailable(String)
    case alreadyStopped
    case unexpectedStop(String?)

    public var description: String {
        switch self {
        case .startTimeout:
            return "Timed out waiting for the Windows VM to finish booting."
        case .invalidSnapshot(let reason):
            return "Unable to use saved VM state: \(reason)"
        case .virtualizationUnavailable(let reason):
            return "Virtualization.framework is unavailable: \(reason)"
        case .alreadyStopped:
            return "The Windows VM is already stopped."
        case .unexpectedStop(let reason):
            if let reason {
                return "The Windows VM stopped unexpectedly: \(reason)"
            }
            return "The Windows VM stopped unexpectedly."
        }
    }
}
