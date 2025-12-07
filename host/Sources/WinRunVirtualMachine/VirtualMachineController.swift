import Foundation
import WinRunShared

public final class VirtualMachineController {
    public private(set) var state: VMState
    private let configuration: VMConfiguration
    private let logger: Logger
    private var uptimeStart: Date?

    public init(configuration: VMConfiguration, logger: Logger = StandardLogger(subsystem: "VirtualMachine")) {
        self.configuration = configuration
        self.logger = logger
        self.state = VMState(status: .stopped, uptime: 0, activeSessions: 0)
    }

    public func ensureRunning() async throws -> VMState {
        switch state.status {
        case .running:
            return state
        case .starting:
            return state
        case .stopped, .suspended:
            return try await start()
        default:
            logger.warn("VM in \(state.status.rawValue) state, retrying start later")
            return state
        }
    }

    public func start() async throws -> VMState {
        logger.info("Starting Windows VM")
        state.status = .starting
        try await Task.sleep(nanoseconds: 500_000_000) // simulate Virtualization.framework boot
        uptimeStart = Date()
        state = VMState(status: .running, uptime: 0, activeSessions: state.activeSessions)
        return state
    }

    public func suspendIfIdle() async throws {
        guard state.activeSessions == 0, state.status == .running else {
            logger.debug("VM still busy, skip suspend")
            return
        }
        logger.info("Suspending Windows VM")
        state.status = .suspending
        try await Task.sleep(nanoseconds: 200_000_000)
        state = VMState(status: .suspended, uptime: uptime(), activeSessions: 0)
        uptimeStart = nil
    }

    public func registerSession(delta: Int) {
        state = VMState(status: state.status, uptime: uptime(), activeSessions: max(0, state.activeSessions + delta))
    }

    public func currentState() -> VMState {
        VMState(status: state.status, uptime: uptime(), activeSessions: state.activeSessions)
    }

    private func uptime() -> TimeInterval {
        guard let start = uptimeStart else { return state.uptime }
        return Date().timeIntervalSince(start)
    }
}
