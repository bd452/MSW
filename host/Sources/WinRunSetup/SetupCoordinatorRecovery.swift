import Foundation
import WinRunShared

// MARK: - SetupCoordinator Recovery Extension

extension SetupCoordinator {
    // MARK: - Error Recovery and Rollback

    /// Cleans up a failed provisioning attempt by deleting the partial disk image.
    ///
    /// Call this method after provisioning fails if you want to free disk space
    /// and start fresh with a new provisioning attempt.
    ///
    /// - Returns: The result of the rollback operation.
    @discardableResult
    public func rollback() async -> RollbackResult {
        guard canPerformRollback else {
            return RollbackResult(
                success: false,
                freedBytes: 0,
                error: WinRunError.configInvalid(
                    reason: "Rollback only available after failed or cancelled provisioning"
                )
            )
        }

        return await performRollbackCleanup()
    }

    /// Performs the actual rollback cleanup.
    private func performRollbackCleanup() async -> RollbackResult {
        guard let ctx = provisioningContext else {
            return RollbackResult(success: true, freedBytes: 0, error: nil)
        }

        var freedBytes: UInt64 = 0
        var rollbackError: WinRunError?

        // Delete the partial disk image if it exists
        let diskPath = ctx.diskImagePath
        if FileManager.default.fileExists(atPath: diskPath.path) {
            do {
                // Get size before deletion
                freedBytes = (try? getDiskUsageForRollback(at: diskPath)) ?? 0
                try deleteDiskImageForRollback(at: diskPath)
            } catch {
                rollbackError = (error as? WinRunError) ?? WinRunError.wrap(error, context: "Rollback")
            }
        }

        // Reset state for retry
        reset()

        return RollbackResult(
            success: rollbackError == nil,
            freedBytes: freedBytes,
            error: rollbackError
        )
    }

    /// Retries provisioning after a failure.
    ///
    /// This is a convenience method that performs rollback and starts a new
    /// provisioning attempt with the same or different configuration.
    ///
    /// - Parameters:
    ///   - configuration: The configuration to use. If nil, uses the previous configuration.
    ///   - performRollback: Whether to delete the partial disk image before retrying.
    /// - Returns: The provisioning result.
    @discardableResult
    public func retry(
        with configuration: SetupCoordinatorConfiguration? = nil,
        performRollback: Bool = true
    ) async -> ProvisioningResult {
        guard canRetry else {
            return createInvalidRetryResult()
        }

        // Get configuration - use provided or reconstruct from previous context
        guard let retryConfig = resolveRetryConfiguration(configuration) else {
            return ProvisioningResult(
                success: false,
                finalPhase: .failed,
                error: WinRunError.configInvalid(reason: "No configuration available for retry"),
                durationSeconds: 0,
                diskImagePath: DiskImageConfiguration.defaultPath
            )
        }

        // Optionally perform rollback
        if performRollback {
            _ = await rollback()
        } else {
            reset()
        }

        // Start fresh provisioning
        return await startProvisioning(with: retryConfig)
    }

    /// Resolves the configuration to use for retry.
    private func resolveRetryConfiguration(
        _ provided: SetupCoordinatorConfiguration?
    ) -> SetupCoordinatorConfiguration? {
        if let config = provided {
            return config
        }
        guard let ctx = provisioningContext else {
            return nil
        }
        return SetupCoordinatorConfiguration(
            isoPath: ctx.isoPath,
            diskImagePath: ctx.diskImagePath
        )
    }

    /// Creates an invalid retry result.
    private func createInvalidRetryResult() -> ProvisioningResult {
        ProvisioningResult(
            success: false,
            finalPhase: currentPhase,
            error: WinRunError.configInvalid(
                reason: "Retry only available after failed or cancelled provisioning"
            ),
            durationSeconds: 0,
            diskImagePath: provisioningContext?.diskImagePath ?? DiskImageConfiguration.defaultPath
        )
    }
}
