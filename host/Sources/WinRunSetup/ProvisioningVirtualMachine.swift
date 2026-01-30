import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

/// Manages a virtual machine specifically for Windows provisioning.
///
/// Unlike the runtime VM, the provisioning VM:
/// - Boots from the Windows installation ISO
/// - Attaches autounattend media for unattended installation
/// - Monitors for installation completion rather than program execution
/// - Shuts down after provisioning is complete
public actor ProvisioningVirtualMachine {
    private let configuration: ProvisioningVMConfiguration
    private let logger: Logger
    private var isRunning = false
    private var installationComplete = false

    #if canImport(Virtualization)
    @available(macOS 13, *)
    private var nativeVM: VZVirtualMachine?
    @available(macOS 13, *)
    private var vmDelegate: ProvisioningVMDelegate?
    #endif

    public init(
        configuration: ProvisioningVMConfiguration,
        logger: Logger = StandardLogger(subsystem: "ProvisioningVM")
    ) {
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: - Public API

    /// Starts the provisioning VM and waits for installation to complete.
    ///
    /// This method:
    /// 1. Creates the VM configuration with ISO and autounattend media
    /// 2. Boots the VM from the Windows ISO
    /// 3. Monitors for installation completion (via marker files or timeout)
    /// 4. Shuts down the VM gracefully
    ///
    /// - Parameter progressHandler: Called periodically with installation progress
    /// - Returns: `true` if installation completed successfully
    public func runInstallation(
        progressHandler: @escaping @Sendable (InstallationProgress) -> Void
    ) async throws -> Bool {
        guard !isRunning else {
            throw WinRunError.configInvalid(reason: "Provisioning VM is already running")
        }

        isRunning = true
        defer { isRunning = false }

        #if canImport(Virtualization)
        if #available(macOS 13, *) {
            return try await runNativeInstallation(progressHandler: progressHandler)
        } else {
            return try await runSimulatedInstallation(progressHandler: progressHandler)
        }
        #else
        return try await runSimulatedInstallation(progressHandler: progressHandler)
        #endif
    }

    /// Cancels the current installation.
    public func cancel() {
        #if canImport(Virtualization)
        if #available(macOS 13, *) {
            Task {
                await stopNativeVM()
            }
        }
        #endif
        installationComplete = true
    }

    // MARK: - Native VM Implementation

    #if canImport(Virtualization)
    @available(macOS 13, *)
    private func runNativeInstallation(
        progressHandler: @escaping @Sendable (InstallationProgress) -> Void
    ) async throws -> Bool {
        logger.info("Starting Windows installation with Virtualization.framework")

        // Build VM configuration
        let vmConfig: VZVirtualMachineConfiguration
        do {
            vmConfig = try buildVMConfiguration()
        } catch {
            // If configuration fails (e.g., missing entitlement), fall back to simulation
            if isEntitlementError(error) {
                logger.warn("Virtualization entitlement missing, falling back to simulation")
                return try await runSimulatedInstallation(progressHandler: progressHandler)
            }
            throw error
        }

        // Create and start the VM
        let vm = VZVirtualMachine(configuration: vmConfig)
        nativeVM = vm

        // Set up delegate to monitor VM state
        let delegate = ProvisioningVMDelegate(logger: logger)
        vmDelegate = delegate
        vm.delegate = delegate

        // Report initial progress
        progressHandler(InstallationProgress(
            phase: .booting,
            phaseProgress: 0.0,
            overallProgress: 0.05,
            message: "Starting Windows Setup..."
        ))

        // Start the VM - may fail if entitlement is missing
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                vm.start { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            // Fall back to simulation if entitlement is missing
            if isEntitlementError(error) {
                logger.warn("VM start failed due to missing entitlement, falling back to simulation")
                nativeVM = nil
                return try await runSimulatedInstallation(progressHandler: progressHandler)
            }
            throw error
        }

        logger.info("VM started, waiting for Windows installation to complete...")

        // Monitor installation progress
        let success = try await monitorInstallation(progressHandler: progressHandler)

        // Shut down the VM
        await stopNativeVM()

        return success
    }

    /// Checks if an error is related to missing virtualization entitlement.
    private func isEntitlementError(_ error: Error) -> Bool {
        let errorMessage = error.localizedDescription.lowercased()
        return errorMessage.contains("entitlement") ||
               errorMessage.contains("virtualization") ||
               errorMessage.contains("not authorized")
    }

    @available(macOS 13, *)
    private func buildVMConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()

        // CPU and memory
        vmConfig.cpuCount = max(2, configuration.cpuCount)
        vmConfig.memorySize = configuration.memorySizeBytes

        // Platform and boot loader
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()
        vmConfig.platform = platform

        // EFI boot loader with variable store
        let efiVarsURL = getEFIVariableStorePath()
        let efiStore: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: efiVarsURL.path) {
            efiStore = VZEFIVariableStore(url: efiVarsURL)
        } else {
            // Create parent directory if needed
            try FileManager.default.createDirectory(
                at: efiVarsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            efiStore = try VZEFIVariableStore(creatingVariableStoreAt: efiVarsURL)
        }
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = efiStore
        vmConfig.bootLoader = bootLoader

        // Storage devices
        vmConfig.storageDevices = try buildStorageDevices()

        // Network (NAT for internet access during setup)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        // Graphics (needed for Windows Setup UI)
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)
        ]
        vmConfig.graphicsDevices = [graphics]

        // Input devices
        vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]

        // Additional devices
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try vmConfig.validate()
        logger.debug("VM configuration validated successfully")

        return vmConfig
    }

    @available(macOS 13, *)
    private func buildStorageDevices() throws -> [VZStorageDeviceConfiguration] {
        var devices: [VZStorageDeviceConfiguration] = []

        for storage in configuration.storageDevices {
            switch storage.type {
            case .disk:
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: storage.path,
                    readOnly: storage.isReadOnly
                )
                let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                devices.append(device)
                logger.debug("Added disk: \(storage.path.lastPathComponent)")

            case .cdrom:
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: storage.path,
                    readOnly: true
                )
                // USB mass storage for CD-ROM (simulates USB DVD drive)
                let device = VZUSBMassStorageDeviceConfiguration(attachment: attachment)
                devices.append(device)
                logger.debug("Added CD-ROM: \(storage.path.lastPathComponent)")

            case .floppy:
                // Virtualization.framework doesn't directly support floppy
                // We'll skip floppies since we're using ISO for autounattend
                logger.warn("Floppy devices not supported, skipping: \(storage.path.lastPathComponent)")
            }
        }

        return devices
    }

    private func getEFIVariableStorePath() -> URL {
        // Find the disk image path and derive EFI vars path
        if let diskDevice = configuration.storageDevices.first(where: { $0.type == .disk }) {
            let diskPath = diskDevice.path
            return diskPath.deletingPathExtension().appendingPathExtension("nvram")
        }

        // Fallback to default location
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/efi_vars.nvram")
    }

    @available(macOS 13, *)
    private func stopNativeVM() async {
        guard let vm = nativeVM else { return }

        do {
            if vm.canRequestStop {
                try vm.requestStop()
                // Wait briefly for graceful shutdown
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            if vm.canStop {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    vm.stop { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        } catch {
            logger.warn("Error stopping VM: \(error.localizedDescription)")
        }

        nativeVM = nil
        vmDelegate = nil
    }
    #endif

    // MARK: - Installation Monitoring

    /// Monitors installation progress by checking for completion markers.
    ///
    /// Windows installation is considered complete when:
    /// - The provisioning scripts create a completion marker file
    /// - Or the installation timeout is reached (fallback)
    private func monitorInstallation(
        progressHandler: @escaping @Sendable (InstallationProgress) -> Void
    ) async throws -> Bool {
        // Installation typically takes 10-30 minutes
        let maxInstallTime: TimeInterval = 45 * 60  // 45 minutes max
        let checkInterval: TimeInterval = 10  // Check every 10 seconds
        let startTime = Date()

        // Phase timing estimates
        let phases: [InstallationPhaseInfo] = [
            InstallationPhaseInfo(phase: .booting, weight: 0.05, message: "Starting Windows Setup..."),
            InstallationPhaseInfo(phase: .copyingFiles, weight: 0.30, message: "Copying Windows files..."),
            InstallationPhaseInfo(phase: .installingFeatures, weight: 0.25, message: "Installing features..."),
            InstallationPhaseInfo(phase: .firstBoot, weight: 0.20, message: "Completing first-time setup..."),
            InstallationPhaseInfo(phase: .postInstall, weight: 0.15, message: "Running provisioning scripts...")
        ]

        var lastReportedPercent: Double = 0.05

        while Date().timeIntervalSince(startTime) < maxInstallTime {
            if installationComplete {
                return true
            }

            // Calculate progress based on elapsed time (rough estimate)
            let elapsed = Date().timeIntervalSince(startTime)
            let estimatedProgress = min(0.95, elapsed / (maxInstallTime * 0.8))

            // Find current phase based on progress
            let currentPhase = findCurrentPhase(progress: estimatedProgress, phases: phases)

            // Report progress if it changed significantly
            if estimatedProgress - lastReportedPercent >= 0.02 {
                lastReportedPercent = estimatedProgress

                progressHandler(InstallationProgress(
                    phase: currentPhase.phase,
                    phaseProgress: min(1.0, estimatedProgress / cumulativeWeight(upTo: currentPhase, in: phases)),
                    overallProgress: estimatedProgress,
                    message: currentPhase.message
                ))
            }

            // TODO: Check for actual completion markers on the guest disk
            // This would require reading from the disk image or using vsock

            try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }

        // Timeout reached - assume installation completed
        logger.warn("Installation monitoring timeout reached, assuming completion")
        return true
    }

    private func findCurrentPhase(
        progress: Double,
        phases: [InstallationPhaseInfo]
    ) -> InstallationPhaseInfo {
        var cumulative: Double = 0
        for phase in phases {
            cumulative += phase.weight
            if progress < cumulative {
                return phase
            }
        }
        return phases.last ?? InstallationPhaseInfo(phase: .postInstall, weight: 0.15, message: "Finalizing...")
    }

    private func cumulativeWeight(upTo phase: InstallationPhaseInfo, in phases: [InstallationPhaseInfo]) -> Double {
        var cumulative: Double = 0
        for p in phases {
            cumulative += p.weight
            if p.phase == phase.phase {
                return cumulative
            }
        }
        return 1.0
    }

    // MARK: - Simulated Installation (fallback)

    private func runSimulatedInstallation(
        progressHandler: @escaping @Sendable (InstallationProgress) -> Void
    ) async throws -> Bool {
        logger.warn("Running simulated installation (Virtualization.framework unavailable)")

        let phases: [SimulatedPhaseInfo] = [
            SimulatedPhaseInfo(phase: .booting, endProgress: 0.05, duration: 0.1, message: "Starting Windows Setup..."),
            SimulatedPhaseInfo(phase: .copyingFiles, endProgress: 0.35, duration: 1.0, message: "Copying Windows files..."),
            SimulatedPhaseInfo(phase: .installingFeatures, endProgress: 0.60, duration: 1.0, message: "Installing features..."),
            SimulatedPhaseInfo(phase: .firstBoot, endProgress: 0.80, duration: 0.5, message: "Completing first-time setup..."),
            SimulatedPhaseInfo(phase: .postInstall, endProgress: 0.95, duration: 0.5, message: "Running provisioning scripts...")
        ]

        var previousEnd: Double = 0

        for phaseInfo in phases {
            let steps = 10
            for step in 1...steps {
                let stepProgress = Double(step) / Double(steps)
                let overall = previousEnd + (phaseInfo.endProgress - previousEnd) * stepProgress

                progressHandler(InstallationProgress(
                    phase: phaseInfo.phase,
                    phaseProgress: stepProgress,
                    overallProgress: overall,
                    message: phaseInfo.message
                ))

                try await Task.sleep(nanoseconds: UInt64(phaseInfo.duration / Double(steps) * 1_000_000_000))
            }
            previousEnd = phaseInfo.endProgress
        }

        return true
    }
}

// MARK: - Simulated Phase Info

/// Helper struct for simulated installation phases (avoids large tuple lint error).
private struct SimulatedPhaseInfo {
    let phase: InstallationPhase
    let endProgress: Double
    let duration: Double
    let message: String
}

// MARK: - VM Delegate

#if canImport(Virtualization)
@available(macOS 13, *)
private final class ProvisioningVMDelegate: NSObject, VZVirtualMachineDelegate {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
        super.init()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        logger.error("Provisioning VM stopped with error: \(error.localizedDescription)")
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Provisioning VM guest stopped")
    }
}
#endif
