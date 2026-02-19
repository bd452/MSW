import Foundation
import WinRunShared
import WinRunVirtualMachine
#if canImport(Virtualization)
import Virtualization
#endif

/// Extension containing Virtualization.framework-specific code for VMProvisioner.
extension VMProvisioner {
    // MARK: - VZ Configuration Building

    #if canImport(Virtualization)
    /// Builds a VZVirtualMachineConfiguration from a ProvisioningVMConfiguration.
    @available(macOS 13, *)
    func buildVZConfiguration(from vmConfig: ProvisioningVMConfiguration) throws -> VZVirtualMachineConfiguration {
        let vzConfig = VZVirtualMachineConfiguration()

        // CPU and memory
        vzConfig.cpuCount = vmConfig.cpuCount
        vzConfig.memorySize = vmConfig.memorySizeBytes

        // Platform
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()
        vzConfig.platform = platform

        // Boot loader with EFI variable store
        guard vmConfig.useEFIBoot else {
            throw WinRunError.configInvalid(
                reason: "Windows installation requires EFI boot")
        }
        vzConfig.bootLoader = try createEFIBootLoader(from: vmConfig)

        // Storage devices
        var storageDevices: [VZStorageDeviceConfiguration] = []
        for device in vmConfig.storageDevices {
            switch device.type {
            case .disk:
                let attachment = try createDiskAttachment(for: device)
                storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))

            case .cdrom:
                let attachment = try createCDROMAttachment(for: device)
                storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))

            case .floppy:
                // Virtualization.framework doesn't support floppy drives directly
                // Autounattend.xml is injected via secondary ISO instead
                break
            }
        }
        vzConfig.storageDevices = storageDevices

        // Network (minimal for installation)
        let networkAttachment = VZNATNetworkDeviceAttachment()
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = networkAttachment
        vzConfig.networkDevices = [networkDevice]

        // Graphics (minimal for installation)
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)
        ]
        vzConfig.graphicsDevices = [graphics]

        // Input devices
        vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        vzConfig.keyboards = [VZUSBKeyboardConfiguration()]

        // Other devices
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Validate configuration
        try vzConfig.validate()

        return vzConfig
    }

    @available(macOS 13, *)
    private func createEFIBootLoader(from vmConfig: ProvisioningVMConfiguration) throws -> VZEFIBootLoader {
        let efiBootLoader = VZEFIBootLoader()
        let variableStorePath = vmConfig.efiVariableStorePath ?? defaultEFIVariableStorePath(from: vmConfig)
        let variableStore = try createOrLoadEFIVariableStore(at: variableStorePath)
        efiBootLoader.variableStore = variableStore
        return efiBootLoader
    }

    @available(macOS 13, *)
    private func defaultEFIVariableStorePath(from vmConfig: ProvisioningVMConfiguration) -> URL {
        vmConfig.storageDevices
            .first { $0.type == .disk }?
            .path
            .deletingLastPathComponent()
            .appendingPathComponent("nvram.bin")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("winrun-nvram.bin")
    }

    @available(macOS 13, *)
    private func createOrLoadEFIVariableStore(at path: URL) throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: path.path) {
            return VZEFIVariableStore(url: path)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: path)
    }

    @available(macOS 13, *)
    private func createDiskAttachment(
        for device: ProvisioningStorageDevice
    ) throws -> VZDiskImageStorageDeviceAttachment {
        do {
            return try VZDiskImageStorageDeviceAttachment(
                url: device.path,
                readOnly: device.isReadOnly
            )
        } catch {
            throw WinRunError.configInvalid(
                reason: "Invalid disk image at \(device.path.path): \(error.localizedDescription)")
        }
    }

    @available(macOS 13, *)
    private func createCDROMAttachment(
        for device: ProvisioningStorageDevice
    ) throws -> VZDiskImageStorageDeviceAttachment {
        do {
            return try VZDiskImageStorageDeviceAttachment(
                url: device.path,
                readOnly: true
            )
        } catch {
            throw WinRunError.configInvalid(
                reason: "Invalid ISO image at \(device.path.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Installation Execution

    @available(macOS 13, *)
    func runInstallationPhasesWithVirtualization(
        configuration: ProvisioningConfiguration,
        vmConfig: ProvisioningVMConfiguration,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        let vzConfig = try createValidatedVZConfig(from: vmConfig)
        let vm = VZVirtualMachine(configuration: vzConfig)
        let initialDiskUsage = try? getDiskUsage(at: configuration.diskImagePath)

        try await startInstallationVM(vm, delegate: delegate, isCancelled: isCancelled)

        try await monitorInstallationProgress(
            vm: vm,
            configuration: configuration,
            initialDiskUsage: initialDiskUsage,
            minimumExpectedDiskUsage: 2 * 1024 * 1024 * 1024,
            delegate: delegate,
            isCancelled: isCancelled
        )

        // Notify delegate to hide the VM display
        await MainActor.run {
            delegate?.installationShouldHideVM()
        }

        reportProgress(
            delegate,
            phase: .postInstall,
            overall: 0.90,
            message: "Windows installation completed, ready for provisioning"
        )
    }

    @available(macOS 13, *)
    private func createValidatedVZConfig(
        from vmConfig: ProvisioningVMConfiguration
    ) throws -> VZVirtualMachineConfiguration {
        let vzConfig: VZVirtualMachineConfiguration
        do {
            vzConfig = try buildVZConfiguration(from: vmConfig)
        } catch let error as WinRunError {
            throw error
        } catch {
            throw WinRunError.configInvalid(
                reason: "Failed to create VM configuration: \(error.localizedDescription)")
        }
        do {
            try vzConfig.validate()
        } catch {
            throw WinRunError.configInvalid(
                reason: "VM configuration validation failed: \(error.localizedDescription)")
        }
        return vzConfig
    }

    @available(macOS 13, *)
    private func startInstallationVM(
        _ vm: VZVirtualMachine,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        reportProgress(
            delegate,
            phase: .copyingFiles,
            overall: 0.10,
            message: "Booting Windows Setup..."
        )
        if isCancelled() { throw WinRunError.cancelled }

        // Create delegate and store strong reference to prevent deallocation
        let vmDelegate = InstallationVMDelegate(onStateChange: { [weak self] state in
            guard let self else { return }
            if state == .running {
                self.reportProgress(
                    delegate,
                    phase: .copyingFiles,
                    overall: 0.15,
                    message: "Windows Setup is running..."
                )
            } else if state == .stopped {
                self.reportProgress(
                    delegate,
                    phase: .firstBoot,
                    overall: 0.80,
                    message: "Windows installation completed, preparing first boot..."
                )
            }
        })
        vm.delegate = vmDelegate
        // Keep delegate alive for the duration of the function
        _ = vmDelegate

        // Notify delegate that VM is starting (for logging/tracking purposes)
        // Note: We don't show VZVirtualMachineView during installation because
        // Windows doesn't have virtio-gpu drivers until after setup completes.
        await MainActor.run {
            delegate?.installationDidProvideVM(vm)
        }

        do {
            try await NativeVirtualMachineBridge.start(vm)
        } catch {
            throw WinRunError.internalError(
                message: "Failed to start VM: \(error.localizedDescription)"
            )
        }

        reportProgress(
            delegate,
            phase: .copyingFiles,
            overall: 0.20,
            message: "Windows Setup is copying files..."
        )
    }

    @available(macOS 13, *)
    private func monitorInstallationProgress(
        vm: VZVirtualMachine,
        configuration: ProvisioningConfiguration,
        initialDiskUsage: UInt64?,
        minimumExpectedDiskUsage: UInt64,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        var lastDiskUsage = initialDiskUsage ?? 0
        var lastProgressUpdate = Date()
        let progressUpdateInterval: TimeInterval = 5.0
        let maxInstallationTime: TimeInterval = 3600
        let installationStartTime = Date()

        while true {
            if isCancelled() {
                try? await NativeVirtualMachineBridge.stop(vm)
                throw WinRunError.cancelled
            }

            let elapsed = Date().timeIntervalSince(installationStartTime)
            if elapsed > maxInstallationTime {
                try? await NativeVirtualMachineBridge.stop(vm)
                throw WinRunError.internalError(
                    message: "Windows installation timed out after \(Int(maxInstallationTime / 60)) minutes")
            }

            let currentDiskUsage = try? getDiskUsage(at: configuration.diskImagePath)
            let vmState = vm.state

            if let currentUsage = currentDiskUsage, currentUsage > lastDiskUsage {
                lastDiskUsage = currentUsage
                updateProgressFromDiskUsage(currentUsage: currentUsage, delegate: delegate)
            }

            if vmState == .stopped {
                try checkInstallationSuccess(currentDiskUsage: currentDiskUsage, delegate: delegate)
                return
            }

            if Date().timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
                updatePeriodicProgress(currentDiskUsage: currentDiskUsage, delegate: delegate)
                lastProgressUpdate = Date()
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    @available(macOS 13, *)
    private func checkInstallationSuccess(
        currentDiskUsage: UInt64?,
        delegate: (any InstallationDelegate)?
    ) throws {
        let usageBytes = currentDiskUsage ?? 0
        let usageGB = Double(usageBytes) / (1024 * 1024 * 1024)

        let minimumSanityCheck: UInt64 = 500 * 1024 * 1024
        if usageBytes < minimumSanityCheck {
            throw WinRunError.internalError(
                message: "Installation failed: disk usage too low (\(String(format: "%.0f", usageGB * 1024)) MB)"
            )
        }

        reportProgress(
            delegate,
            phase: .firstBoot,
            overall: 0.85,
            message: "Windows installation completed (\(String(format: "%.1f", usageGB)) GB)"
        )
    }

    @available(macOS 13, *)
    private func updateProgressFromDiskUsage(
        currentUsage: UInt64,
        delegate: (any InstallationDelegate)?
    ) {
        let estimatedGB = Double(currentUsage) / (1024 * 1024 * 1024)
        let installationProgress = min(0.7, 0.2 + (estimatedGB / 15.0) * 0.5)

        let phase: InstallationPhase
        let message: String
        if estimatedGB < 2 {
            phase = .copyingFiles
            message = "Copying Windows files..."
        } else if estimatedGB < 8 {
            phase = .installingFeatures
            message = "Installing Windows features..."
        } else {
            phase = .firstBoot
            message = "Completing installation..."
        }

        reportProgress(
            delegate,
            phase: phase,
            overall: installationProgress,
            message: message
        )
    }

    @available(macOS 13, *)
    private func updatePeriodicProgress(
        currentDiskUsage: UInt64?,
        delegate: (any InstallationDelegate)?
    ) {
        if let currentUsage = currentDiskUsage {
            let estimatedGB = Double(currentUsage) / (1024 * 1024 * 1024)
            let message = "Installing Windows... (\(String(format: "%.1f", estimatedGB)) GB used)"
            reportProgress(
                delegate,
                phase: .installingFeatures,
                overall: 0.50,
                message: message
            )
        }
    }
    #endif
}

// MARK: - Installation VM Delegate

#if canImport(Virtualization)
/// Delegate for monitoring VM state changes during installation.
@available(macOS 13, *)
class InstallationVMDelegate: NSObject, VZVirtualMachineDelegate {
    let onStateChange: (VZVirtualMachine.State) -> Void

    init(onStateChange: @escaping (VZVirtualMachine.State) -> Void) {
        self.onStateChange = onStateChange
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStateChange(.stopped)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStateChange(.stopped)
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        // Ignore network errors during installation
    }
}
#endif
