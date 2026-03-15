import AppKit
import Foundation
import WinRunSetup
import WinRunShared

@available(macOS 13, *)
extension SetupWizardCoordinator {
    static func createManualInstallViewController(
        coordinator: SetupWizardCoordinator
    ) -> NSViewController {
        let vc = ManualInstallViewController()
        vc.onLaunchInstaller = { [weak coordinator] in
            coordinator?.launchManualInstaller()
        }
        vc.onFinishRequested = { [weak coordinator] in
            coordinator?.finishManualSetup()
        }
        vc.onChooseDifferentISO = { [weak coordinator] in
            coordinator?.chooseNewISO()
        }

        for line in coordinator.manualDiagnostics {
            vc.appendDiagnostic(line)
        }

        if let configuration = coordinator.manualInstallationConfiguration {
            Task { [weak coordinator, weak vc] in
                guard let coordinator, let vc else { return }
                do {
                    let preflight = try await coordinator.manualProvisioner.installerPreflight(
                        configuration: configuration
                    )
                    await MainActor.run {
                        vc.updatePreflight(preflight)
                    }
                } catch {
                    await MainActor.run {
                        vc.appendDiagnostic("Preflight failed: \(error.localizedDescription)")
                        vc.setStatus("Installer preflight failed. Check diagnostics and prerequisites.", isError: true)
                    }
                }
            }
        } else {
            vc.setStatus("Select a Windows ISO before launching manual install.", isError: true)
        }

        return vc
    }

    static func createFailureContext(
        from result: ProvisioningResult,
        coordinator: SetupWizardCoordinator
    ) -> SetupFailureContext? {
        guard !result.success, let error = result.error else { return nil }

        let freeDiskSpace: UInt64? = {
            let url = coordinator.diskImagePath.deletingLastPathComponent()
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage.map { UInt64($0) }
        }()

        return SetupFailureContext(
            failedPhase: result.finalPhase,
            error: error,
            isoPath: coordinator.selectedISOPath,
            diskImagePath: result.diskImagePath,
            diskUsageBytes: result.diskUsageBytes,
            freeDiskSpaceBytes: freeDiskSpace,
            cleanupRecommended: result.finalPhase.isAfter(.creatingDisk)
        )
    }

    var manualInstallationConfiguration: ProvisioningConfiguration? {
        guard let isoPath = selectedISOPath else { return nil }
        return ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskImagePath
        )
    }

    func shouldFallbackToManualInstall(for error: WinRunError?) -> Bool {
        guard let error else { return false }
        switch error {
        case .notSupported, .installerLaunchFailed:
            return true
        case .configInvalid(let reason):
            let lower = reason.lowercased()
            return lower.contains("installer") || lower.contains("qemu") || lower.contains("firmware")
        default:
            return false
        }
    }

    func observeManualSessionExit(_ session: InstallerLaunchSession) {
        manualInstallerWatchTask?.cancel()
        manualInstallerWatchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let exitCode = try await session.waitForExit(isCancelled: { Task.isCancelled })
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.manualInstallSession = nil
                    self.manualProvisioner.clearManualInstallationSession()
                    if exitCode == 0 {
                        self.appendManualDiagnostic("Installer VM exited cleanly.")
                    } else {
                        self.appendManualDiagnostic("Installer VM exited with code \(exitCode).")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.manualInstallSession = nil
                    self.manualProvisioner.clearManualInstallationSession()
                    let wasCancelled: Bool = {
                        if let winRunError = error as? WinRunError, case .cancelled = winRunError {
                            return true
                        }
                        return false
                    }()
                    if !wasCancelled {
                        self.appendManualDiagnostic("Installer VM stopped: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func appendManualDiagnostic(_ line: String) {
        manualDiagnostics.append(line)
        if manualDiagnostics.count > 500 {
            manualDiagnostics.removeFirst(manualDiagnostics.count - 500)
        }
        (window?.contentViewController as? ManualInstallViewController)?.appendDiagnostic(line)
    }

    func setManualStatus(_ message: String, isError: Bool) {
        (window?.contentViewController as? ManualInstallViewController)?
            .setStatus(message, isError: isError)
    }

    func markSetupInProgress() {
        do {
            try setupMarkerStore.markInProgress(diskImagePath: diskImagePath)
        } catch {
            logger.warn("Failed to persist setup marker (in progress): \(error.localizedDescription)")
        }
    }

    func markSetupCompleted() {
        do {
            try setupMarkerStore.markCompleted(diskImagePath: diskImagePath)
        } catch {
            logger.warn("Failed to persist setup marker (completed): \(error.localizedDescription)")
        }
    }
}

@available(macOS 13, *)
extension SetupWizardCoordinator: ProvisioningDelegate {
    public func provisioningDidUpdateProgress(_ progress: ProvisioningProgress) {
        Task { @MainActor [weak self] in
            guard let self, self.currentStep == .installing else { return }
            if let progressVC = self.window?.contentViewController as? InstallProgressViewController {
                progressVC.apply(progress: progress)
            }
        }
    }

    public func provisioningDidChangePhase(from oldPhase: ProvisioningPhase, to newPhase: ProvisioningPhase) {
        logger.debug("Provisioning phase: \(oldPhase.rawValue) -> \(newPhase.rawValue)")
    }

    public func provisioningDidComplete(with result: ProvisioningResult) {
        Task { @MainActor [weak self] in
            self?.handleInstallationComplete(result: result)
        }
    }
}
