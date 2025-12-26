import Foundation
import WinRunShared
import WinRunSpiceBridge

// MARK: - Provisioning Channel Bridge

/// Bridges the `SpiceControlChannel` delegate to the `SetupCoordinator`.
///
/// This class implements `SpiceControlChannelDelegate` and routes provisioning
/// messages to the appropriate `SetupCoordinator` instance. Since `SetupCoordinator`
/// is an actor, this bridge handles the async dispatch.
///
/// ## Usage
///
/// ```swift
/// let controlChannel = SpiceControlChannel()
/// let coordinator = SetupCoordinator(controlChannel: controlChannel)
/// let bridge = ProvisioningChannelBridge(coordinator: coordinator)
/// controlChannel.delegate = bridge
/// ```
public final class ProvisioningChannelBridge: SpiceControlChannelDelegate, @unchecked Sendable {
    private weak var coordinator: SetupCoordinator?

    /// Creates a bridge that routes messages to the given coordinator.
    public init(coordinator: SetupCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - SpiceControlChannelDelegate

    public func controlChannelDidConnect(_ channel: SpiceControlChannel) {
        // Connection established - coordinator is notified via its own mechanisms
    }

    public func controlChannelDidDisconnect(_ channel: SpiceControlChannel) {
        // Connection lost - coordinator handles timeout/error internally
    }

    public func controlChannel(
        _ channel: SpiceControlChannel,
        didReceiveMessage message: Any,
        type: SpiceMessageType
    ) {
        // Route provisioning messages to the coordinator
        Task {
            await coordinator?.routeSpiceMessage(message, type: type)
        }
    }
}
