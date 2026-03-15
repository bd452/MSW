import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

public enum VirtualMachineLifecycleError: Error, CustomStringConvertible, LocalizedError {
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
            return "VM backend is unavailable: \(reason)"
        case .alreadyStopped:
            return "The Windows VM is already stopped."
        case .unexpectedStop(let reason):
            if let reason {
                return "The Windows VM stopped unexpectedly: \(reason)"
            }
            return "The Windows VM stopped unexpectedly."
        }
    }

    public var errorDescription: String? {
        description
    }
}

public actor VirtualMachineController {
    public private(set) var state: VMState
    let configuration: VMConfiguration
    let logger: Logger
    private var uptimeStart: Date?
    private var configurationValidated = false
    private var bootCount: Int = 0
    private var suspendCount: Int = 0
    private var totalSessionsLaunched: Int = 0
    private var idleSuspendTask: Task<Void, Never>?
    private var runtimeManager: QEMURuntimeProcessManager?
    private var runtimeMonitorTask: Task<Void, Never>?

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

        if let manager = runtimeManager {
            await manager.stop()
        }
        runtimeManager = nil
        runtimeMonitorTask?.cancel()
        runtimeMonitorTask = nil

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

        if let manager = runtimeManager {
            await manager.stop()
        }
        runtimeManager = nil
        runtimeMonitorTask?.cancel()
        runtimeMonitorTask = nil
        cleanupSharedMemory()
        uptimeStart = nil
        state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
        logMetrics(event: "vm_shutdown")
        return state
    }

    @discardableResult
    public func saveSnapshot(to url: URL? = nil) async throws -> URL {
        _ = url
        throw VirtualMachineLifecycleError.invalidSnapshot(
            "Snapshot save is not yet supported with the QEMU runtime backend"
        )
    }

    // MARK: - Private helpers

    private func start(resumeFromSnapshot: Bool) async throws -> VMState {
        fputs("[VM] start() called, current status=\(state.status.rawValue), resumeFromSnapshot=\(resumeFromSnapshot)\n", stderr)

        if state.status == .running {
            fputs("[VM] Already running, returning current state\n", stderr)
            return snapshotState()
        }
        if state.status == .starting {
            fputs("[VM] Already starting, waiting for ready\n", stderr)
            return try await waitForReady()
        }

        fputs("[VM] Validating configuration...\n", stderr)
        try validateConfigurationIfNeeded()
        fputs("[VM] Configuration validated\n", stderr)

        state.status = .starting
        fputs("[VM] Status set to 'starting'\n", stderr)
        logger.info(resumeFromSnapshot ? "Resuming Windows VM from snapshot" : "Booting Windows VM")
        if resumeFromSnapshot {
            logger.info("QEMU backend resumes with a cold boot (snapshot restore not implemented)")
        }
        let manager = runtimeManager ?? QEMURuntimeProcessManager(logger: logger)
        do {
            try await manager.start(configuration: configuration)
            runtimeManager = manager
            startRuntimeMonitor()
        } catch {
            state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
            throw VirtualMachineLifecycleError.virtualizationUnavailable(error.localizedDescription)
        }

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
            if state.status == .starting {
                try runtimeManager?.checkHealth()
            }
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

    // MARK: - VM Delegate Handlers

    /// Called when the guest VM stops gracefully (e.g., shutdown from within Windows).
    func handleGuestDidStop() {
        logger.info("Handling graceful VM stop")
        cancelIdleSuspendTimer()
        runtimeMonitorTask?.cancel()
        runtimeMonitorTask = nil
        runtimeManager = nil
        cleanupSharedMemory()
        uptimeStart = nil
        state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
        logMetrics(event: "vm_guest_stopped")
    }

    /// Called when the guest VM stops unexpectedly with an error.
    func handleGuestDidStopWithError(_ error: Error) {
        logger.error("Handling unexpected VM stop: \(error.localizedDescription)")
        cancelIdleSuspendTimer()
        runtimeMonitorTask?.cancel()
        runtimeMonitorTask = nil
        runtimeManager = nil
        cleanupSharedMemory()
        uptimeStart = nil
        state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
        logMetrics(event: "vm_unexpected_stop")
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
    @available(macOS 13, *)
    func getVsockDevice() -> VZVirtioSocketDevice? {
        nil
    }
#endif

    private func startRuntimeMonitor() {
        runtimeMonitorTask?.cancel()
        runtimeMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                do {
                    try await self.runtimeManager?.checkHealth()
                } catch {
                    await self.handleGuestDidStopWithError(error)
                    return
                }
            }
        }
    }
}
