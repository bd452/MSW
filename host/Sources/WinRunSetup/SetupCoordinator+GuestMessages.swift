import Foundation
import WinRunShared
import WinRunSpiceBridge

extension SetupCoordinator {
    /// Handles a provisioning progress message from the guest.
    public func handleProvisionProgress(_ message: ProvisionProgressMessage) {
        guard currentState.phase == .postInstallProvisioning else { return }

        let overallProgress = mapGuestPhaseToProgress(
            message.phase, phaseProgress: message.progressFraction)
        updateProgress(phaseProgress: overallProgress, message: message.message)
    }

    /// Handles a provisioning error message from the guest.
    /// - Returns: Whether provisioning should continue (if error is recoverable).
    @discardableResult
    public func handleProvisionError(_ message: ProvisionErrorMessage) -> Bool {
        guard currentState.phase == .postInstallProvisioning else { return false }

        let errorMessage =
            "[\(message.phase.rawValue)] \(message.message) "
            + "(0x\(String(message.errorCode, radix: 16)))"

        if message.isRecoverable {
            updateProgress(
                phaseProgress: currentState.phaseProgress,
                message: "Warning: \(message.message)"
            )
            return true
        } else {
            provisioningError = WinRunError.internalError(message: errorMessage)
            return false
        }
    }

    /// Handles a provisioning complete message from the guest.
    public func handleProvisionComplete(_ message: ProvisionCompleteMessage) {
        guard currentState.phase == .postInstallProvisioning else { return }

        if message.success {
            context?.windowsVersion = message.windowsVersion
            context?.agentVersion = message.agentVersion
            context?.diskUsageBytes = message.diskUsageBytes
            updateProgress(phaseProgress: 1.0, message: "Guest provisioning complete")
            provisioningComplete = true
        } else {
            let errorMessage = message.errorMessage ?? "Guest provisioning failed"
            provisioningError = WinRunError.internalError(message: errorMessage)
        }
    }

    func mapGuestPhaseToProgress(
        _ phase: GuestProvisioningPhase,
        phaseProgress: Double
    ) -> Double {
        calculateGuestPhaseProgress(phase, phaseProgress: phaseProgress)
    }

    /// Routes a Spice message to the appropriate handler.
    public func routeSpiceMessage(_ message: Any, type: SpiceMessageType) {
        switch type {
        case .provisionProgress:
            if let msg = message as? ProvisionProgressMessage {
                guestMessageContinuation?.yield(.progress(msg))
            }
        case .provisionError:
            if let msg = message as? ProvisionErrorMessage {
                guestMessageContinuation?.yield(.error(msg))
            }
        case .provisionComplete:
            if let msg = message as? ProvisionCompleteMessage {
                guestMessageContinuation?.yield(.complete(msg))
            }
        default:
            break
        }
    }

    /// Injects a provisioning progress message (for testing).
    public func injectProvisionProgress(_ message: ProvisionProgressMessage) {
        guestMessageContinuation?.yield(.progress(message))
    }

    /// Injects a provisioning error message (for testing).
    public func injectProvisionError(_ message: ProvisionErrorMessage) {
        guestMessageContinuation?.yield(.error(message))
    }

    /// Injects a provisioning complete message (for testing).
    public func injectProvisionComplete(_ message: ProvisionCompleteMessage) {
        guestMessageContinuation?.yield(.complete(message))
    }
}
