import Foundation
import WinRunShared

public protocol WinRunDaemonXPC {
    func ensureVMRunning(reply: @escaping (Result<VMState, Error>) -> Void)
    func executeProgram(_ request: ProgramLaunchRequest, reply: @escaping (Result<Void, Error>) -> Void)
    func getStatus(reply: @escaping (Result<VMState, Error>) -> Void)
    func suspendIfIdle(reply: @escaping (Result<Void, Error>) -> Void)
}

public final class WinRunDaemonClient {
    private let logger: Logger

    public init(logger: Logger = StandardLogger(subsystem: "WinRunDaemonClient")) {
        self.logger = logger
    }

    public func ensureVMRunning() async throws -> VMState {
        logger.debug("Requesting VM resume")
        return try await send { handler in
            handler.ensureVMRunning(reply: $0)
        }
    }

    public func executeProgram(_ request: ProgramLaunchRequest) async throws {
        logger.info("Launching \(request.windowsPath)")
        _ = try await send { handler in
            handler.executeProgram(request, reply: $0)
        }
    }

    public func status() async throws -> VMState {
        logger.debug("Fetching VM status")
        return try await send { handler in
            handler.getStatus(reply: $0)
        }
    }

    public func suspendIfIdle() async throws {
        logger.info("Requesting idle suspend")
        _ = try await send { handler in
            handler.suspendIfIdle(reply: $0)
        }
    }

    private func send<Value>(
        _ block: (_ handler: WinRunDaemonXPC, _ completion: @escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            #if os(macOS)
            let connection = NSXPCConnection(machServiceName: "com.winrun.daemon", options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: WinRunDaemonXPC.self)
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
                connection.invalidate()
            }) as? WinRunDaemonXPC else {
                continuation.resume(throwing: WinRunError.ipcFailure)
                connection.invalidate()
                return
            }
            block(proxy) { result in
                connection.invalidate()
                continuation.resume(with: result)
            }
            #else
            // On non-macOS platforms we cannot form an XPC connection; back deployments use mocks.
            continuation.resume(throwing: WinRunError.ipcFailure)
            #endif
        }
    }
}
