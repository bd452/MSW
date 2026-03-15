import AppKit
import Foundation
import WinRunShared
/// Displays the raw VM framebuffer via the existing Spice stream pipeline.
/// Used as a direct desktop fallback when the guest agent is unavailable.
@available(macOS 13, *)
final class VMConsoleWindowController: NSObject {
    private let logger: Logger
    private let streamWindowController: WinRunWindowController
    private var isPresented = false

    init(logger: Logger = StandardLogger(subsystem: "VMConsoleWindow")) {
        self.logger = logger
        self.streamWindowController = WinRunWindowController()
        super.init()
    }

    func showConsole(agentStatus: AgentStatus = .checking) {
        if isPresented {
            updateAgentStatus(agentStatus)
            return
        }

        fputs("[CONSOLE] Opening Spice-backed console window\n", stderr)
        streamWindowController.presentWindow(title: "Windows VM Console")
        NSApplication.shared.activate(ignoringOtherApps: true)
        isPresented = true
        updateAgentStatus(agentStatus)
    }

    func updateAgentStatus(_ status: AgentStatus) {
        // Keep this for continuity with existing call-sites. With the Spice-native
        // fallback window, status is currently logged rather than shown as a titlebar banner.
        switch status {
        case .checking:
            logger.info("Console status: checking for WinRunAgent")
        case .notFound:
            logger.info("Console status: WinRunAgent not detected")
        case .connected:
            logger.info("Console status: WinRunAgent connected")
        }
    }

    var isVisible: Bool { isPresented }

    // MARK: - Banner

    enum AgentStatus {
        case checking
        case notFound
        case connected
    }
}
