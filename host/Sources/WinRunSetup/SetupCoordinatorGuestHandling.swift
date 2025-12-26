import Foundation
import WinRunShared
import WinRunSpiceBridge

// MARK: - Guest Provisioning Event

/// Events received from the guest during post-install provisioning.
public enum GuestProvisioningEvent: Sendable {
    case progress(ProvisionProgressMessage)
    case error(ProvisionErrorMessage)
    case complete(ProvisionCompleteMessage)
}

// MARK: - SetupCoordinator Guest Provisioning Extension

extension SetupCoordinator {
    // MARK: - Guest Provisioning Waiting

    /// Waits for guest provisioning messages via the Spice control channel.
    ///
    /// This creates an async stream and waits for provisioning events from the guest.
    /// The control channel delegate routes incoming messages to this stream.
    func waitForGuestProvisioningMessages(
        using stream: AsyncStream<GuestProvisioningEvent>,
        timeout: Duration = .seconds(1800)
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Process incoming guest messages
            group.addTask {
                for await event in stream {
                    switch event {
                    case .progress(let message):
                        await self.handleProvisionProgress(message)
                    case .error(let message):
                        let canContinue = await self.handleProvisionError(message)
                        if !canContinue {
                            throw WinRunError.internalError(
                                message: "Provisioning failed: \(message.message)"
                            )
                        }
                    case .complete(let message):
                        await self.handleProvisionComplete(message)
                        if message.success {
                            return  // Success - exit the loop
                        } else {
                            throw WinRunError.internalError(
                                message: message.errorMessage ?? "Provisioning failed"
                            )
                        }
                    }
                }
            }

            // Task 2: Timeout watchdog
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WinRunError.internalError(
                    message: "Guest provisioning timed out after \(timeout.components.seconds / 60) minutes"
                )
            }

            // Task 3: Cancellation watchdog
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 100_000_000)  // Check every 100ms
                    if await self.checkCancelled() {
                        throw WinRunError.cancelled
                    }
                }
            }

            // Wait for completion or error
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Guest Phase Progress Mapping

    /// Maps a guest provisioning phase to overall post-install progress (0.0 to 1.0).
    func calculateGuestPhaseProgress(_ phase: GuestProvisioningPhase, phaseProgress: Double) -> Double {
        let phaseWeights: [GuestProvisioningPhase: (start: Double, weight: Double)] = [
            .drivers: (0.0, 0.25),
            .agent: (0.25, 0.25),
            .optimize: (0.50, 0.30),
            .finalize: (0.80, 0.15),
            .complete: (0.95, 0.05),
        ]

        guard let info = phaseWeights[phase] else {
            return phaseProgress
        }

        return info.start + (info.weight * phaseProgress)
    }
}
