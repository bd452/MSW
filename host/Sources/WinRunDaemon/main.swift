import Foundation
import WinRunShared
import WinRunVirtualMachine
import WinRunXPC

final class WinRunDaemonService: WinRunDaemonXPC {
    private let vmController: VirtualMachineController
    private let logger: Logger

    init(configuration: VMConfiguration = VMConfiguration(), logger: Logger = StandardLogger(subsystem: "winrund")) {
        self.vmController = VirtualMachineController(configuration: configuration, logger: logger)
        self.logger = logger
    }

    func ensureVMRunning(reply: @escaping (Result<VMState, Error>) -> Void) {
        Task { [vmController] in
            do {
                let state = try await vmController.ensureRunning()
                reply(.success(state))
            } catch {
                reply(.failure(error))
            }
        }
    }

    func executeProgram(_ request: ProgramLaunchRequest, reply: @escaping (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let strongSelf = self else {
                reply(.failure(WinRunError.ipcFailure))
                return
            }
            do {
                _ = try await strongSelf.vmController.ensureRunning()
                strongSelf.logger.info("Would launch \(request.windowsPath) with args \(request.arguments)")
                await strongSelf.vmController.registerSession(delta: 1)
                reply(.success(()))
            } catch {
                reply(.failure(error))
            }
        }
    }

    func getStatus(reply: @escaping (Result<VMState, Error>) -> Void) {
        Task { [vmController] in
            let status = await vmController.currentState()
            reply(.success(status))
        }
    }

    func suspendIfIdle(reply: @escaping (Result<Void, Error>) -> Void) {
        Task { [vmController] in
            do {
                try await vmController.suspendIfIdle()
                reply(.success(()))
            } catch {
                reply(.failure(error))
            }
        }
    }

    func snapshot() async -> VMState {
        await vmController.currentState()
    }
}

@main
struct WinRunDaemonMain {
    static func main() {
        let logger = StandardLogger(subsystem: "winrund-main")
        logger.info("Starting winrund mock service (XPC not active in this environment)")
        let service = WinRunDaemonService()
        let runLoop = RunLoop.current
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task {
                let status = await service.snapshot()
                logger.debug("VM status: \(status.status.rawValue), sessions: \(status.activeSessions)")
            }
        }
        runLoop.run()
    }
}
