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
        var storageLayout: [String] = []
        if let serialPort = makeInstallBootSerialPortConfiguration() {
            vzConfig.serialPorts = [serialPort]
        }

        // CPU and memory
        vzConfig.cpuCount = vmConfig.cpuCount
        vzConfig.memorySize = vmConfig.memorySizeBytes

        // Platform
        let platform = VZGenericPlatformConfiguration()
        let machineIdentifierPath = vmConfig.machineIdentifierPath ?? defaultMachineIdentifierPath(from: vmConfig)
        platform.machineIdentifier = try createOrLoadMachineIdentifier(at: machineIdentifierPath)
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
                if #available(macOS 14, *) {
                    storageDevices.append(VZNVMExpressControllerDeviceConfiguration(attachment: attachment))
                    storageLayout.append("disk:nvme:\(device.path.lastPathComponent)")
                } else {
                    storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
                    storageLayout.append("disk:virtio-block:\(device.path.lastPathComponent)")
                }

            case .cdrom:
                let attachment = try createCDROMAttachment(for: device)
                if device.isBootable {
                    switch bootISOMode() {
                    case .virtioBlock:
                        // Primary mode: expose installer media as block-backed optical path.
                        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
                        storageLayout.append("cdrom:virtio-block:bootable:\(device.path.lastPathComponent)")
                    case .usbMassStorage:
                        // Fallback mode: surface installer media as removable USB storage.
                        storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
                        storageLayout.append("cdrom:usb-mass-storage:bootable:\(device.path.lastPathComponent)")
                    }
                } else {
                    // Keep auxiliary install media on USB so WinPE can still discover
                    // autounattend/drivers with inbox USB storage support.
                    storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
                    storageLayout.append("cdrom:usb-mass-storage:auxiliary:\(device.path.lastPathComponent)")
                }

            case .floppy:
                // Virtualization.framework doesn't support floppy drives directly
                // Autounattend.xml is injected via secondary ISO instead
                break
            }
        }
        vzConfig.storageDevices = storageDevices
        logger.info(
            "Configured VM storage layout",
            metadata: ["layout": .string(storageLayout.joined(separator: ","))]
        )
        logProvisioningStorageRoles(vmConfig)

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

    private enum BootISOMode: String {
        case virtioBlock
        case usbMassStorage
    }

    private func bootISOMode() -> BootISOMode {
        if ProcessInfo.processInfo.environment["WINRUN_BOOT_ISO_AS_USB"] == "1" {
            logger.warn("Using fallback installer boot mode: usb-mass-storage")
            return .usbMassStorage
        }
        return .virtioBlock
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
            .first { $0.type == .disk }
            .map(\.path)
            .map { VMArtifactPaths.nvramPath(for: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("winrun-nvram.bin")
    }

    @available(macOS 13, *)
    private func defaultMachineIdentifierPath(from vmConfig: ProvisioningVMConfiguration) -> URL {
        vmConfig.storageDevices
            .first { $0.type == .disk }
            .map(\.path)
            .map { VMArtifactPaths.machineIdentifierPath(for: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("winrun-machine-identifier.bin")
    }

    @available(macOS 13, *)
    private func createOrLoadEFIVariableStore(at path: URL) throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: path.path) {
            logger.debug("Loading existing EFI variable store", metadata: ["path": .string(path.path)])
            return VZEFIVariableStore(url: path)
        }
        logger.debug("Creating new EFI variable store", metadata: ["path": .string(path.path)])
        return try VZEFIVariableStore(creatingVariableStoreAt: path)
    }

    @available(macOS 13, *)
    private func createOrLoadMachineIdentifier(at path: URL) throws -> VZGenericMachineIdentifier {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            if let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
                logger.debug("Loaded persisted machine identifier", metadata: ["path": .string(path.path)])
                return identifier
            }
            throw WinRunError.configInvalid(
                reason: "Invalid machine identifier at \(path.path)")
        }

        let identifier = VZGenericMachineIdentifier()
        try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try identifier.dataRepresentation.write(to: path)
        logger.debug("Created new machine identifier", metadata: ["path": .string(path.path)])
        return identifier
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

    @available(macOS 13, *)
    private func makeInstallBootSerialPortConfiguration() -> VZSerialPortConfiguration? {
        let logURL = LoggerFactory.defaultLogDirectory.appendingPathComponent("winrun-install-boot.log")
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: Data())
            }

            let writeHandle = try FileHandle(forWritingTo: logURL)
            try writeHandle.seekToEnd()
            if let banner = "[\(Date())] ---- installer boot session ----\n".data(using: .utf8) {
                writeHandle.write(banner)
            }

            let attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.standardInput,
                fileHandleForWriting: writeHandle
            )
            let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
            serialPort.attachment = attachment
            logger.info("Provisioning boot serial logging enabled", metadata: ["path": .string(logURL.path)])
            return serialPort
        } catch {
            logger.warn("Failed to enable provisioning boot serial logging: \(error)")
            return nil
        }
    }

    private func logProvisioningStorageRoles(_ vmConfig: ProvisioningVMConfiguration) {
        let bootMedia = vmConfig.storageDevices.first(where: { $0.type == .cdrom && $0.isBootable })?.path.path
        let targetDisk = vmConfig.storageDevices.first(where: { $0.type == .disk })?.path.path
        let auxiliaryMedia = vmConfig.storageDevices
            .filter { $0.type == .cdrom && !$0.isBootable }
            .map(\.path.path)
            .joined(separator: ",")

        logger.info(
            "Provisioning storage roles",
            metadata: [
                "bootMedia": .string(bootMedia ?? "none"),
                "targetDisk": .string(targetDisk ?? "none"),
                "auxiliaryMedia": .string(auxiliaryMedia.isEmpty ? "none" : auxiliaryMedia),
            ]
        )
    }

    // MARK: - Installation Execution

    @available(macOS 13, *)
    func runInstallationPhasesWithVirtualization(
        configuration: ProvisioningConfiguration,
        vmConfig: ProvisioningVMConfiguration,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        logger.info(
            "Running installation phases with Virtualization.framework",
            metadata: [
                "diskImagePath": .string(configuration.diskImagePath.path),
                "storageDevices": .int(vmConfig.storageDevices.count),
            ]
        )
        let vzConfig = try createValidatedVZConfig(from: vmConfig)
        let vm = VZVirtualMachine(configuration: vzConfig)
        let initialDiskUsage = try? getDiskUsage(at: configuration.diskImagePath)
        logger.debug(
            "Virtual machine created",
            metadata: [
                "vmState": .string(String(describing: vm.state)),
                "initialDiskUsageBytes": .int(Int(initialDiskUsage ?? 0)),
            ]
        )

        try await startInstallationVM(
            vm,
            configuration: configuration,
            delegate: delegate,
            isCancelled: isCancelled
        )

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
        logger.info("Virtualization install phases completed")
    }

    @available(macOS 13, *)
    private func createValidatedVZConfig(
        from vmConfig: ProvisioningVMConfiguration
    ) throws -> VZVirtualMachineConfiguration {
        logger.debug(
            "Building VZVirtualMachineConfiguration",
            metadata: [
                "cpuCount": .int(vmConfig.cpuCount),
                "memoryGB": .int(vmConfig.memorySizeGB),
                "storageDevices": .int(vmConfig.storageDevices.count),
            ]
        )
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
        logger.debug("VZVirtualMachineConfiguration validated successfully")
        return vzConfig
    }

    @available(macOS 13, *)
    // swiftlint:disable function_body_length
    private func startInstallationVM(
        _ vm: VZVirtualMachine,
        configuration: ProvisioningConfiguration,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        let interactiveMode = shouldExposeInteractiveInstallDisplay(configuration: configuration)
        let bootMessage = interactiveMode
            ? "Booting Windows Setup (interactive)..."
            : "Booting Windows Setup (unattended)..."
        reportProgress(
            delegate,
            phase: .copyingFiles,
            overall: 0.10,
            message: bootMessage
        )
        logger.info(
            "Starting VM for installation",
            metadata: [
                "interactiveMode": .bool(interactiveMode),
                "hasAutounattend": .bool(configuration.autounattendPath != nil),
                "hasVirtioDrivers": .bool(configuration.virtioDriversPath != nil),
            ]
        )
        if isCancelled() { throw WinRunError.cancelled }

        // Create delegate and store strong reference to prevent deallocation
        let vmDelegate = InstallationVMDelegate(
            onStateChange: { [weak self] state in
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
            },
            onStopError: { [weak self] error in
                self?.logger.error("VM stopped with error during installation: \(error)")
            }
        )
        vm.delegate = vmDelegate
        // Keep delegate alive for the duration of the function
        _ = vmDelegate

        if interactiveMode {
            logger.info("Exposing VM display window to delegate before VM boot")
            await MainActor.run {
                delegate?.installationDidProvideVM(vm)
            }
        }

        do {
            try await NativeVirtualMachineBridge.start(vm)
        } catch {
            throw WinRunError.internalError(
                message: "Failed to start VM: \(error.localizedDescription)"
            )
        }
        logger.info("VM started successfully", metadata: ["vmState": .string(String(describing: vm.state))])

        reportProgress(
            delegate,
            phase: .copyingFiles,
            overall: 0.20,
            message: "Windows Setup is copying files..."
        )
    }
    // swiftlint:enable function_body_length

    private func shouldExposeInteractiveInstallDisplay(configuration: ProvisioningConfiguration) -> Bool {
        if ProcessInfo.processInfo.environment["WINRUN_SHOW_INSTALLATION_VM_WINDOW"] == "1" {
            return true
        }
        // If unattended assets are unavailable, manual fallback requires interactive display.
        return configuration.autounattendPath == nil
    }

    @available(macOS 13, *)
    // swiftlint:disable function_body_length
    private func monitorInstallationProgress(
        vm: VZVirtualMachine,
        configuration: ProvisioningConfiguration,
        initialDiskUsage: UInt64?,
        minimumExpectedDiskUsage: UInt64,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        var lastDiskUsage = initialDiskUsage ?? 0
        var noGrowthWarningIssued = false
        var lastNoGrowthWarningElapsed: TimeInterval = 0
        var hasShownStallRecoveryWindow = false
        var lastProgressUpdate = Date()
        var lastHeartbeat = Date()
        var lastLoggedState = vm.state
        let progressUpdateInterval: TimeInterval = 5.0
        let heartbeatInterval: TimeInterval = 15.0
        let noGrowthWarningThreshold: TimeInterval = 60.0
        let noGrowthReminderInterval: TimeInterval = 120.0
        let maxInstallationTime: TimeInterval = 3600
        let installationStartTime = Date()

        logger.info(
            "Monitoring installation progress loop",
            metadata: [
                "maxInstallationSeconds": .int(Int(maxInstallationTime)),
                "minimumExpectedDiskUsageBytes": .int(Int(minimumExpectedDiskUsage)),
            ]
        )

        while true {
            if isCancelled() {
                logger.warn("Cancellation detected during install monitor; stopping VM")
                try? await NativeVirtualMachineBridge.stop(vm)
                throw WinRunError.cancelled
            }

            let elapsed = Date().timeIntervalSince(installationStartTime)
            if elapsed > maxInstallationTime {
                logger.error("Installation timed out; stopping VM")
                try? await NativeVirtualMachineBridge.stop(vm)
                throw WinRunError.internalError(
                    message: "Windows installation timed out after \(Int(maxInstallationTime / 60)) minutes")
            }

            let currentDiskUsage = try? getDiskUsage(at: configuration.diskImagePath)
            let vmState = vm.state
            if vmState != lastLoggedState {
                logger.info(
                    "VM state changed during install",
                    metadata: [
                        "oldState": .string(String(describing: lastLoggedState)),
                        "newState": .string(String(describing: vmState)),
                    ]
                )
                lastLoggedState = vmState
            }

            if let currentUsage = currentDiskUsage, currentUsage > lastDiskUsage {
                lastDiskUsage = currentUsage
                logger.debug("Disk usage increased during install", metadata: ["diskUsageBytes": .int(Int(currentUsage))])
                updateProgressFromDiskUsage(currentUsage: currentUsage, delegate: delegate)
            }
            if lastDiskUsage == (initialDiskUsage ?? 0), elapsed >= noGrowthWarningThreshold {
                if !noGrowthWarningIssued || (elapsed - lastNoGrowthWarningElapsed) >= noGrowthReminderInterval {
                    logger.warn(
                        "Installer has not written to disk yet; likely stalled before setup handoff",
                        metadata: [
                            "elapsedSeconds": .int(Int(elapsed)),
                            "diskPath": .string(configuration.diskImagePath.path),
                            "diskUsageBytes": .int(Int(currentDiskUsage ?? 0)),
                            "isoPath": .string(configuration.isoPath.path),
                            "hasAutounattend": .bool(configuration.autounattendPath != nil),
                            "hint": .string("Check Win11 setup requirements gate (TPM/SecureBoot) or unattended media discovery"),
                        ]
                    )
                    if !hasShownStallRecoveryWindow {
                        hasShownStallRecoveryWindow = true
                        logger.warn(
                            "Showing VM window for manual recovery after unattended stall"
                        )
                        await MainActor.run {
                            delegate?.installationDidProvideVM(vm)
                        }
                        reportProgress(
                            delegate,
                            phase: .copyingFiles,
                            overall: 0.20,
                            message: "Windows Setup appears stalled. Manual interaction window opened."
                        )
                    }
                    noGrowthWarningIssued = true
                    lastNoGrowthWarningElapsed = elapsed
                }
            }

            if vmState == .stopped {
                logger.info("VM stopped; evaluating installation success")
                try checkInstallationSuccess(currentDiskUsage: currentDiskUsage, delegate: delegate)
                return
            }

            if Date().timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
                updatePeriodicProgress(currentDiskUsage: currentDiskUsage, delegate: delegate)
                lastProgressUpdate = Date()
            }

            if Date().timeIntervalSince(lastHeartbeat) >= heartbeatInterval {
                logger.debug(
                    "Installation heartbeat",
                    metadata: [
                        "elapsedSeconds": .int(Int(elapsed)),
                        "vmState": .string(String(describing: vmState)),
                        "diskUsageBytes": .int(Int(currentDiskUsage ?? 0)),
                    ]
                )
                lastHeartbeat = Date()
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    // swiftlint:enable function_body_length

    @available(macOS 13, *)
    private func checkInstallationSuccess(
        currentDiskUsage: UInt64?,
        delegate: (any InstallationDelegate)?
    ) throws {
        let usageBytes = currentDiskUsage ?? 0
        let usageGB = Double(usageBytes) / (1024 * 1024 * 1024)
        logger.info("Checking installation completion", metadata: ["diskUsageBytes": .int(Int(usageBytes))])

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
        logger.info("Installation completion sanity check passed")
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
        logger.debug(
            "Progress updated from disk usage",
            metadata: [
                "phase": .string(phase.rawValue),
                "overallProgress": .double(installationProgress),
                "diskUsageBytes": .int(Int(currentUsage)),
            ]
        )
    }

    @available(macOS 13, *)
    private func updatePeriodicProgress(
        currentDiskUsage: UInt64?,
        delegate: (any InstallationDelegate)?
    ) {
        if let currentUsage = currentDiskUsage {
            if currentUsage == 0 {
                reportProgress(
                    delegate,
                    phase: .copyingFiles,
                    overall: 0.20,
                    message: "Waiting for Windows Setup to start..."
                )
                logger.debug("Periodic progress update emitted", metadata: ["diskUsageBytes": .int(0)])
                return
            }

            let estimatedGB = Double(currentUsage) / (1024 * 1024 * 1024)
            let phase: InstallationPhase = estimatedGB < 2 ? .copyingFiles : .installingFeatures
            let progress = estimatedGB < 2 ? 0.30 : 0.50
            let message = "Installing Windows... (\(String(format: "%.1f", estimatedGB)) GB used)"
            reportProgress(
                delegate,
                phase: phase,
                overall: progress,
                message: message
            )
            logger.debug("Periodic progress update emitted", metadata: ["diskUsageBytes": .int(Int(currentUsage))])
        } else {
            logger.debug("Periodic progress update skipped; disk usage unavailable")
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
    let onStopError: (Error) -> Void

    init(
        onStateChange: @escaping (VZVirtualMachine.State) -> Void,
        onStopError: @escaping (Error) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onStopError = onStopError
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStopError(error)
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
