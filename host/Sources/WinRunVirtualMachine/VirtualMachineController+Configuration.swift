import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

#if canImport(Virtualization)
extension VirtualMachineController {
    // swiftlint:disable function_body_length
    @available(macOS 13, *)
    func buildNativeConfiguration() throws -> VZVirtualMachineConfiguration {
        fputs("[VM-CONFIG] Building VZ configuration\n", stderr)
        fputs("[VM-CONFIG] Disk image: \(configuration.diskImagePath.path)\n", stderr)
        let diskExists = FileManager.default.fileExists(atPath: configuration.diskImagePath.path)
        fputs("[VM-CONFIG] Disk exists: \(diskExists)\n", stderr)
        if diskExists {
            let attrs = try? FileManager.default.attributesOfItem(atPath: configuration.diskImagePath.path)
            let diskSize = attrs?[.size] as? UInt64 ?? 0
            fputs("[VM-CONFIG] Disk size: \(diskSize) bytes (\(diskSize / 1024 / 1024 / 1024) GB)\n", stderr)
        }

        let vmConfig = VZVirtualMachineConfiguration()
        vmConfig.cpuCount = max(2, configuration.resources.cpuCount)
        vmConfig.memorySize = UInt64(configuration.resources.memorySizeGB) * 1024 * 1024 * 1024
        fputs("[VM-CONFIG] CPUs=\(vmConfig.cpuCount), RAM=\(vmConfig.memorySize / 1024 / 1024)MB\n", stderr)

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try loadOrCreateMachineIdentifier()
        vmConfig.platform = platform
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try ensureEFIVariableStore()
        vmConfig.bootLoader = bootLoader
        fputs("[VM-CONFIG] EFI boot loader configured\n", stderr)

        let blockAttachment = try VZDiskImageStorageDeviceAttachment(
            url: configuration.diskImagePath, readOnly: false)
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: blockAttachment)
        vmConfig.storageDevices = [blockDevice]
        fputs("[VM-CONFIG] Block storage attached\n", stderr)

        let networkAttachment = try makeNetworkAttachment()
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = networkAttachment

        if let macAddressString = configuration.network.macAddress,
           let macAddress = VZMACAddress(string: macAddressString) {
            networkDevice.macAddress = macAddress
            logger.debug("Applied custom MAC address: \(macAddressString)")
        }

        vmConfig.networkDevices = [networkDevice]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200),
        ]
        vmConfig.graphicsDevices = [graphics]
        fputs("[VM-CONFIG] VirtIO graphics: 1920x1200 scanout\n", stderr)

        vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let soundDevice = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        soundDevice.streams = [outputStream]
        vmConfig.audioDevices = [soundDevice]
        fputs("[VM-CONFIG] Audio device added\n", stderr)

        try configureFrameStreamingDevices(vmConfig)

        logger.info(
            "VM config: \(vmConfig.cpuCount) CPUs, "
                + "\(vmConfig.memorySize / 1024 / 1024)MB RAM, "
                + "disk=\(configuration.diskImagePath.lastPathComponent), "
                + "graphics=\(vmConfig.graphicsDevices.count) devices, "
                + "storage=\(vmConfig.storageDevices.count) devices"
        )

        try vmConfig.validate()
        logger.info("VM configuration validated successfully")
        return vmConfig
    }
    // swiftlint:enable function_body_length

    @available(macOS 13, *)
    private func configureFrameStreamingDevices(
        _ vmConfig: VZVirtualMachineConfiguration
    ) throws {
        let frameConfig = configuration.frameStreaming
        fputs("[VM-CONFIG] Frame streaming: vsock=\(frameConfig.vsockEnabled), "
              + "spiceConsole=\(frameConfig.spiceConsoleEnabled), "
              + "sharedMem=\(frameConfig.sharedMemoryEnabled) (\(frameConfig.sharedMemorySizeMB)MB)\n", stderr)

        // Defer advanced streaming devices until the guest agent is installed
        // and VirtIO drivers are confirmed. Only add them when the agent is
        // expected to be available, to avoid EFI device-enumeration issues.
        fputs("[VM-CONFIG] Skipping advanced streaming devices (vsock/console/VirtioFS) "
              + "— not needed until guest agent is installed\n", stderr)
    }

    @available(macOS 13, *)
    func loadOrCreateMachineIdentifier() throws -> VZGenericMachineIdentifier {
        let idPath = configuration.diskImagePath
            .deletingLastPathComponent()
            .appendingPathComponent("machine-identifier.bin")

        if FileManager.default.fileExists(atPath: idPath.path) {
            let data = try Data(contentsOf: idPath)
            if let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
                fputs("[VM-CONFIG] Loaded machine identifier from \(idPath.path)\n", stderr)
                return identifier
            }
            fputs("[VM-CONFIG] Failed to parse machine-identifier.bin, creating new\n", stderr)
        }

        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: idPath)
        fputs("[VM-CONFIG] Created and saved new machine identifier to \(idPath.path)\n", stderr)
        return identifier
    }

    @available(macOS 13, *)
    func ensureEFIVariableStore() throws -> VZEFIVariableStore {
        let storePath = configuration.diskImagePath
            .deletingPathExtension()
            .appendingPathExtension("efi-variable-store")

        if FileManager.default.fileExists(atPath: storePath.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: storePath.path)
            let size = attrs?[.size] as? UInt64 ?? 0
            let modified = attrs?[.modificationDate] as? Date
            fputs("[EFI] Reusing existing EFI variable store: \(storePath.path) "
                  + "(size=\(size) bytes, modified=\(modified?.description ?? "unknown"))\n", stderr)
            return VZEFIVariableStore(url: storePath)
        }

        let parentDir = storePath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true)
        }
        fputs("[EFI] Creating NEW EFI variable store at \(storePath.path)\n", stderr)
        logger.info("Creating new EFI variable store at \(storePath.path)")
        return try VZEFIVariableStore(creatingVariableStoreAt: storePath)
    }

    @available(macOS 13, *)
    func makeNetworkAttachment() throws -> VZNetworkDeviceAttachment {
        switch configuration.network.mode {
        case .nat:
            return VZNATNetworkDeviceAttachment()
        case .bridged:
            guard let identifier = configuration.network.interfaceIdentifier else {
                throw VMConfigurationValidationError.bridgedInterfaceNotSpecified
            }
            guard let interface = VZBridgedNetworkInterface.networkInterfaces.first(where: {
                $0.identifier == identifier || $0.localizedDisplayName == identifier
            }) else {
                throw VMConfigurationValidationError.bridgedInterfaceUnavailable(identifier)
            }
            return VZBridgedNetworkDeviceAttachment(interface: interface)
        }
    }
}
#endif
