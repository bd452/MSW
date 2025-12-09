import Foundation
import WinRunShared
import WinRunVirtualMachine
import WinRunXPC

@objc final class WinRunDaemonService: NSObject, WinRunDaemonXPC {
    private let vmController: VirtualMachineController
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: VMConfiguration = VMConfiguration(), logger: Logger = StandardLogger(subsystem: "winrund")) {
        self.vmController = VirtualMachineController(configuration: configuration, logger: logger)
        self.logger = logger
    }

    func ensureVMRunning(_ reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            do {
                let state = try await vmController.ensureRunning()
                reply(try encode(state), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func executeProgram(_ requestData: NSData, reply: @escaping (NSError?) -> Void) {
        Task { [self] in
            do {
                let request = try decode(ProgramLaunchRequest.self, from: requestData)
                _ = try await vmController.ensureRunning()
                logger.info("Would launch \(request.windowsPath) with args \(request.arguments)")
                await vmController.registerSession(delta: 1)
                reply(nil)
            } catch {
                reply(nsError(error))
            }
        }
    }

    func getStatus(_ reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            let status = await vmController.currentState()
            do {
                reply(try encode(status), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func suspendIfIdle(_ reply: @escaping (NSError?) -> Void) {
        Task { [self] in
            do {
                try await vmController.suspendIfIdle()
                reply(nil)
            } catch {
                reply(nsError(error))
            }
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> NSData {
        try NSData(data: encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: NSData) throws -> T {
        try decoder.decode(T.self, from: data as Data)
    }

    private func nsError(_ error: Error) -> NSError {
        if let nsError = error as NSError? {
            return nsError
        }
        return NSError(domain: "com.winrun.daemon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: error.localizedDescription
        ])
    }
}

final class WinRunDaemonListener: NSObject, NSXPCListenerDelegate {
    private let logger: Logger
    private let service: WinRunDaemonService

    init(service: WinRunDaemonService, logger: Logger) {
        self.service = service
        self.logger = logger
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WinRunDaemonXPC.self)
        connection.exportedObject = service
        connection.resume()
        logger.info("Accepted new XPC connection \(connection)")
        return true
    }
}

@main
struct WinRunDaemonMain {
    static func main() {
        let logger = StandardLogger(subsystem: "winrund-main")
        logger.info("Starting winrund XPC service")

        let service = WinRunDaemonService(logger: logger)
        let listenerDelegate = WinRunDaemonListener(service: service, logger: logger)
        let listener = NSXPCListener(machServiceName: "com.winrun.daemon")
        listener.delegate = listenerDelegate
        listener.resume()

        RunLoop.main.run()
    }
}
