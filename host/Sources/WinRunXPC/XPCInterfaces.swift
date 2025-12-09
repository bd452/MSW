import Foundation
import WinRunShared

@objc public protocol WinRunDaemonXPC {
    func ensureVMRunning(_ reply: @escaping (NSData?, NSError?) -> Void)
    func executeProgram(_ requestData: NSData, reply: @escaping (NSError?) -> Void)
    func getStatus(_ reply: @escaping (NSData?, NSError?) -> Void)
    func suspendIfIdle(_ reply: @escaping (NSError?) -> Void)
}

public final class WinRunDaemonClient {
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let machServiceName = "com.winrun.daemon"

    public init(logger: Logger = StandardLogger(subsystem: "WinRunDaemonClient")) {
        self.logger = logger
    }

    public func ensureVMRunning() async throws -> VMState {
        logger.debug("Requesting VM resume")
        return try await send { handler, completion in
            handler.ensureVMRunning { data, error in
                completion(self.decodeResponse(type: VMState.self, data: data, error: error))
            }
        }
    }

    public func executeProgram(_ request: ProgramLaunchRequest) async throws {
        logger.info("Launching \(request.windowsPath)")
        let requestData = try encode(request)
        _ = try await send { handler, completion in
            handler.executeProgram(requestData) { error in
                completion(self.decodeVoid(error: error))
            }
        }
    }

    public func status() async throws -> VMState {
        logger.debug("Fetching VM status")
        return try await send { handler, completion in
            handler.getStatus { data, error in
                completion(self.decodeResponse(type: VMState.self, data: data, error: error))
            }
        }
    }

    public func suspendIfIdle() async throws {
        logger.info("Requesting idle suspend")
        _ = try await send { handler, completion in
            handler.suspendIfIdle { error in
                completion(self.decodeVoid(error: error))
            }
        }
    }

    private func send<Value>(
        _ block: (_ handler: WinRunDaemonXPC, _ completion: @escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            #if os(macOS)
            let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
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
            continuation.resume(throwing: WinRunError.ipcFailure)
            #endif
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> NSData {
        try NSData(data: encoder.encode(value))
    }

    private func decodeResponse<T: Decodable>(type: T.Type, data: NSData?, error: NSError?) -> Result<T, Error> {
        if let error {
            return .failure(error)
        }
        guard let data else {
            return .failure(WinRunError.ipcFailure)
        }
        do {
            let decoded = try decoder.decode(T.self, from: data as Data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    private func decodeVoid(error: NSError?) -> Result<Void, Error> {
        if let error {
            return .failure(error)
        }
        return .success(())
    }
}
