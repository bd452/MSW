import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

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

public actor VirtualMachineController {
    public private(set) var state: VMState
    private let configuration: VMConfiguration
    private let logger: Logger
    private var uptimeStart: Date?
    private var suspendedStateURL: URL?
    private var configurationValidated = false
    private var bootCount: Int = 0
    private var suspendCount: Int = 0
    private var totalSessionsLaunched: Int = 0
    private var idleSuspendTask: Task<Void, Never>?

#if canImport(Virtualization)
    @available(macOS 13, *)
    private var nativeVM: VZVirtualMachine?
    @available(macOS 13, *)
    private var cachedConfiguration: VZVirtualMachineConfiguration?
    @available(macOS 13, *)
    private var vmDelegate: VirtualMachineDelegate?

    /// The vsock device for guest-host communication, available after VM starts.
    @available(macOS 13, *)
    private var vsockDevice: VZVirtioSocketDevice? {
        nativeVM?.socketDevices.first as? VZVirtioSocketDevice
    }
#endif

    /// The frame streaming configuration for this VM.
    public var frameStreamingConfiguration: FrameStreamingConfiguration {
        configuration.frameStreaming
    }

    public init(configuration: VMConfiguration, logger: Logger = StandardLogger(subsystem: "VirtualMachine")) {
        self.configuration = configuration
        self.logger = logger
        self.state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
    }

    @discardableResult
    public func ensureRunning() async throws -> VMState {
        switch state.status {
        case .running:
            return snapshotState()
        case .starting, .suspending:
            return try await waitForReady()
        case .suspended:
            return try await start(resumeFromSnapshot: true)
        case .stopped, .stopping:
            return try await start(resumeFromSnapshot: false)
        }
    }

    @discardableResult
    public func start() async throws -> VMState {
        try await start(resumeFromSnapshot: false)
    }

    public func registerSession(delta: Int) {
        let updated = max(0, state.activeSessions + delta)
        state = VMState(status: state.status, uptime: uptime(), activeSessions: updated)
        if delta > 0 {
            totalSessionsLaunched += delta
            logMetrics(event: "session_opened")
            cancelIdleSuspendTimer()
        } else if delta < 0 {
            logMetrics(event: "session_closed")
            if updated == 0 {
                scheduleIdleSuspendTimer(reason: "no active sessions remain")
            }
        }
    }

    public func currentState() -> VMState {
        snapshotState()
    }

    public func suspendIfIdle() async throws {
        guard state.activeSessions == 0 else {
            logger.debug("Skipping suspend; \(state.activeSessions) sessions active")
            return
        }
        guard state.status == .running else {
            logger.debug("VM not running; current state is \(state.status.rawValue)")
            return
        }

        cancelIdleSuspendTimer()
        state.status = .suspending
        logger.info("Suspending Windows VM after idle timeout")
        let snapshotURL = try await saveSnapshotInternal(to: defaultSnapshotURL())

#if canImport(Virtualization)
        if #available(macOS 13, *), let vm = nativeVM {
            try await NativeVirtualMachineBridge.stop(vm)
        } else {
            try await simulateShutdown()
        }
#else
        try await simulateShutdown()
#endif

        suspendedStateURL = snapshotURL
        clearNativeVM()
        let uptimeSeconds = uptime()
        suspendCount += 1
        uptimeStart = nil
        state = VMState(status: .suspended, uptime: uptimeSeconds, activeSessions: 0)
        logMetrics(event: "vm_suspended")
    }

    @discardableResult
    public func shutdown() async throws -> VMState {
        guard state.status == .running || state.status == .suspended || state.status == .starting else {
            throw VirtualMachineLifecycleError.alreadyStopped
        }
        cancelIdleSuspendTimer()
        logger.info("Stopping Windows VM")
        state.status = .stopping

#if canImport(Virtualization)
        if #available(macOS 13, *), let vm = nativeVM {
            try await NativeVirtualMachineBridge.stop(vm)
        } else {
            try await simulateShutdown()
        }
#else
        try await simulateShutdown()
#endif

        clearNativeVM()
        cleanupSharedMemory()
        uptimeStart = nil
        state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
        logMetrics(event: "vm_shutdown")
        return state
    }

    @discardableResult
    public func saveSnapshot(to url: URL? = nil) async throws -> URL {
        guard state.status == .running else {
            throw VirtualMachineLifecycleError.invalidSnapshot("VM must be running to capture state")
        }
        let destination = url ?? defaultSnapshotURL()
        return try await saveSnapshotInternal(to: destination)
    }

    // MARK: - Private helpers

    private func start(resumeFromSnapshot: Bool) async throws -> VMState {
        if state.status == .running {
            return snapshotState()
        }
        if state.status == .starting {
            return try await waitForReady()
        }

        try validateConfigurationIfNeeded()

        state.status = .starting
        logger.info(resumeFromSnapshot ? "Resuming Windows VM from snapshot" : "Booting Windows VM")

#if canImport(Virtualization)
        if #available(macOS 13, *) {
            do {
                try await bootNativeVirtualMachine(resumeFromSnapshot: resumeFromSnapshot)
            } catch let validationError as VMConfigurationValidationError {
                logger.error("Failed to build VM configuration: \(validationError.description)")
                throw VirtualMachineLifecycleError.virtualizationUnavailable(validationError.description)
            }
        } else {
            try await simulateBoot()
        }
#else
        try await simulateBoot()
#endif

        uptimeStart = Date()
        state = VMState(status: .running, uptime: 0, activeSessions: state.activeSessions)
        bootCount += 1
        let event = resumeFromSnapshot ? "vm_resumed" : "vm_started"
        logMetrics(event: event)
        if state.activeSessions == 0 {
            scheduleIdleSuspendTimer(reason: "no active sessions after start")
        } else {
            cancelIdleSuspendTimer()
        }
        return state
    }

    private func waitForReady(timeout: TimeInterval = 60) async throws -> VMState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.status == .running || state.status == .stopped || state.status == .suspended {
                return snapshotState()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw VirtualMachineLifecycleError.startTimeout
    }

    private func snapshotState() -> VMState {
        let current = VMState(status: state.status, uptime: uptime(), activeSessions: state.activeSessions)
        state = current
        return current
    }

    private func uptime() -> TimeInterval {
        guard let start = uptimeStart else { return state.uptime }
        return Date().timeIntervalSince(start)
    }

    private func defaultSnapshotURL() -> URL {
        configuration.diskImagePath.deletingPathExtension().appendingPathExtension("vmstate")
    }

    private func scheduleIdleSuspendTimer(reason: String) {
        guard configuration.suspendOnIdleAfterSeconds > 0 else {
            return
        }
        guard state.status == .running, state.activeSessions == 0 else {
            return
        }

        idleSuspendTask?.cancel()
        let delayNanos = UInt64(configuration.suspendOnIdleAfterSeconds * 1_000_000_000)
        logger.info("Scheduling VM suspend in \(Int(configuration.suspendOnIdleAfterSeconds))s (\(reason))")
        idleSuspendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            await self?.handleIdleTimeout()
        }
    }

    private func cancelIdleSuspendTimer() {
        idleSuspendTask?.cancel()
        idleSuspendTask = nil
    }

    private func handleIdleTimeout() async {
        do {
            try await suspendIfIdle()
        } catch {
            logger.warn("Idle suspend skipped: \(error)")
        }
    }

    private func clearNativeVM() {
#if canImport(Virtualization)
        nativeVM = nil
        cachedConfiguration = nil
        vmDelegate = nil
#endif
    }

    // MARK: - VM Delegate Handlers

    /// Called when the guest VM stops gracefully (e.g., shutdown from within Windows).
    func handleGuestDidStop() {
        logger.info("Handling graceful VM stop")
        cancelIdleSuspendTimer()
        clearNativeVM()
        cleanupSharedMemory()
        uptimeStart = nil
        state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
        logMetrics(event: "vm_guest_stopped")
    }

    /// Called when the guest VM stops unexpectedly with an error.
    func handleGuestDidStopWithError(_ error: Error) {
        logger.error("Handling unexpected VM stop: \(error.localizedDescription)")
        cancelIdleSuspendTimer()
        clearNativeVM()
        cleanupSharedMemory()
        uptimeStart = nil
        state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
        logMetrics(event: "vm_unexpected_stop")
    }

    private func saveSnapshotInternal(to url: URL) async throws -> URL {
#if canImport(Virtualization)
        if #available(macOS 13, *), let vm = nativeVM {
            try await NativeVirtualMachineBridge.saveMachineState(vm, to: url)
        } else {
            try await simulateSnapshot()
        }
#else
        try await simulateSnapshot()
#endif
        suspendedStateURL = url
        return url
    }

    private func simulateBoot() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func simulateShutdown() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    private func simulateSnapshot() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func validateConfigurationIfNeeded() throws {
        guard !configurationValidated else { return }
        do {
            try configuration.validate()
            configurationValidated = true
            logger.debug("Validated VM configuration for disk \(configuration.disk.imagePath.path)")
        } catch let validationError as VMConfigurationValidationError {
            logger.error("VM configuration invalid: \(validationError.description)")
            throw VirtualMachineLifecycleError.virtualizationUnavailable(validationError.description)
        } catch {
            logger.error("VM configuration validation hit unexpected error: \(error)")
            throw VirtualMachineLifecycleError.virtualizationUnavailable(error.localizedDescription)
        }
    }

    private func logMetrics(event: String) {
        let snapshot = VMMetricsSnapshot(
            event: event,
            uptimeSeconds: uptime(),
            activeSessions: state.activeSessions,
            totalSessions: totalSessionsLaunched,
            bootCount: bootCount,
            suspendCount: suspendCount
        )
        logger.info("VM metrics: \(snapshot.description)")
    }

    #if canImport(Virtualization)
    /// Returns the vsock device if available. Used by VirtualMachineVsock extension.
    @available(macOS 13, *)
    func getVsockDevice() -> VZVirtioSocketDevice? {
        vsockDevice
    }
    #endif

#if canImport(Virtualization)
    @available(macOS 13, *)
    private func bootNativeVirtualMachine(resumeFromSnapshot: Bool) async throws {
        let config = try cachedConfiguration ?? buildNativeConfiguration()
        cachedConfiguration = config

        let vm: VZVirtualMachine
        if let existing = nativeVM {
            vm = existing
        } else {
            vm = VZVirtualMachine(configuration: config)
            nativeVM = vm

            // Set up the delegate to receive VM lifecycle events
            let delegate = VirtualMachineDelegate(controller: self, logger: logger)
            vmDelegate = delegate
            vm.delegate = delegate
        }

        if resumeFromSnapshot, let resumeURL = suspendedStateURL, FileManager.default.fileExists(atPath: resumeURL.path) {
            try await NativeVirtualMachineBridge.restoreMachineState(vm, from: resumeURL)
            suspendedStateURL = nil
        } else {
            try await NativeVirtualMachineBridge.start(vm)
        }
    }

    @available(macOS 13, *)
    private func buildNativeConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()
        vmConfig.cpuCount = max(2, configuration.resources.cpuCount)
        vmConfig.memorySize = UInt64(configuration.resources.memorySizeGB) * 1024 * 1024 * 1024

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()
        vmConfig.platform = platform
        vmConfig.bootLoader = VZEFIBootLoader()

        let blockAttachment = try VZDiskImageStorageDeviceAttachment(url: configuration.diskImagePath, readOnly: false)
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: blockAttachment)
        vmConfig.storageDevices = [blockDevice]

        let networkAttachment = try makeNetworkAttachment()
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = networkAttachment

        // Apply custom MAC address if configured
        if let macAddressString = configuration.network.macAddress,
           let macAddress = VZMACAddress(string: macAddressString) {
            networkDevice.macAddress = macAddress
            logger.debug("Applied custom MAC address: \(macAddressString)")
        }

        vmConfig.networkDevices = [networkDevice]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        vmConfig.graphicsDevices = [graphics]

        vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Configure frame streaming devices
        try configureFrameStreamingDevices(vmConfig)

        try vmConfig.validate()
        return vmConfig
    }

    /// Configures vsock, shared memory, and console devices for frame streaming.
    @available(macOS 13, *)
    private func configureFrameStreamingDevices(_ vmConfig: VZVirtualMachineConfiguration) throws {
        let frameConfig = configuration.frameStreaming

        // Add VirtIO socket device for vsock communication
        if frameConfig.vsockEnabled {
            let vsockDevice = VZVirtioSocketDeviceConfiguration()
            vmConfig.socketDevices = [vsockDevice]
            logger.debug("Configured vsock device for frame streaming")
        }

        // Add VirtIO console device for Spice port channel
        if frameConfig.spiceConsoleEnabled {
            let consoleDevice = VZVirtioConsoleDeviceConfiguration()
            // VZVirtioConsoleDeviceConfiguration has a default port at index 0
            // Configure it for our Spice control channel using index access
            if let port = consoleDevice.ports[0] {
                port.name = "com.winrun.spice"
                port.isConsole = false
            }
            vmConfig.consoleDevices = [consoleDevice]
            logger.debug("Configured Spice console port for control channel")
        }

        // Add VirtioFS device for shared memory frame buffer
        if frameConfig.sharedMemoryEnabled {
            let fsDevice = try createFrameBufferShareDevice()
            vmConfig.directorySharingDevices = [fsDevice]
            logger.debug(
                "Configured VirtioFS device for shared frame buffer " +
                "(size: \(frameConfig.sharedMemorySizeMB)MB, tag: \(SharedMemoryManager.virtioFSTag))"
            )
        }
    }

    @available(macOS 13, *)
    private func makeNetworkAttachment() throws -> VZNetworkDeviceAttachment {
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
#endif
}
