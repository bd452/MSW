import AppKit
import Foundation
import WinRunSetup
import WinRunShared
import WinRunVirtualMachine
import WinRunXPC

/// Application delegate managing WinRun app lifecycle and menu bar.
@available(macOS 13, *)
final class WinRunApplicationDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider: VMServiceProvider = {
        switch RuntimeEnvironment.current.serviceMode {
        case .embedded: return EmbeddedServiceProvider()
        case .xpc: return WinRunDaemonClient()
        }
    }()
    private let logger = StandardLogger(subsystem: "WinRunApp")
    private let windowController = WinRunWindowController()
    private let consoleWindowController = VMConsoleWindowController()
    private var setupFlowController: SetupFlowController?
    private let settingsController = SettingsWindowController.shared
    private var bootInProgress = false

    func start(arguments: [String]) {
        setupMenuBar()

        let preflight = ProvisioningPreflight.evaluate()
        let setupFlowController = SetupFlowController(preflight: preflight)
        self.setupFlowController = setupFlowController
        setupFlowController.routeToSetupOrNormalOperation { [self] in
            let executable = arguments.dropFirst().first ?? "C:/Windows/System32/notepad.exe"
            Task { @MainActor in
                await self.bootAndLaunch(executable)
            }
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()
        let windowMenu = createWindowMenu()
        let helpMenu = createHelpMenu()

        mainMenu.addItem(createAppMenuItem())
        mainMenu.addItem(createFileMenuItem())
        mainMenu.addItem(createEditMenuItem())
        mainMenu.addItem(createWindowMenuItem(windowMenu: windowMenu))
        mainMenu.addItem(createHelpMenuItem(helpMenu: helpMenu))

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
        NSApplication.shared.helpMenu = helpMenu
    }

    private func createAppMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            NSMenuItem(title: "About WinRun", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Show VM Console",
                action: #selector(openConsole),
                keyEquivalent: ""))
        appMenu.addItem(
            NSMenuItem(
                title: "Maintenance Boot (QEMU)…",
                action: #selector(startMaintenanceBoot),
                keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Hide WinRun", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        )

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit WinRun",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        return appMenuItem
    }

    private func createFileMenuItem() -> NSMenuItem {
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))

        return fileMenuItem
    }

    private func createEditMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        return editMenuItem
    }

    private func createWindowMenu() -> NSMenu {
        let windowMenu = NSMenu(title: "Window")

        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        ))

        return windowMenu
    }

    private func createWindowMenuItem(windowMenu: NSMenu) -> NSMenuItem {
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        return windowMenuItem
    }

    private func createHelpMenu() -> NSMenu {
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(
            NSMenuItem(title: "WinRun Help", action: #selector(showHelp), keyEquivalent: "?"))
        return helpMenu
    }

    private func createHelpMenuItem(helpMenu: NSMenu) -> NSMenuItem {
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        return helpMenuItem
    }

    // MARK: - Boot + Launch

    @MainActor
    private func bootAndLaunch(_ executable: String) async {
        guard !bootInProgress else {
            logger.warn("Ignoring duplicate bootAndLaunch while boot is already in progress")
            return
        }
        bootInProgress = true
        defer { bootInProgress = false }

        fputs("[APP] bootAndLaunch starting, executable=\(executable)\n", stderr)
        fputs("[APP] serviceMode=\(RuntimeEnvironment.current.serviceMode)\n", stderr)

        // Embedded mode: start QEMU runtime in-process, then open Spice console.
        if let embedded = serviceProvider as? EmbeddedServiceProvider {
            await bootEmbedded(embedded)
            return
        }

        // XPC/daemon mode: single-step boot + agent launch
        do {
            _ = try await serviceProvider.ensureVMRunning()
        } catch {
            logger.error("Failed to start VM: \(error)")
            showVMError(
                title: "Could not start Windows VM",
                detail: error.localizedDescription,
                recovery: "Make sure the WinRun daemon is installed and running.\n"
                    + "You can install it with: make install-daemon"
            )
            return
        }

        do {
            let request = ProgramLaunchRequest(windowsPath: executable)
            try await serviceProvider.executeProgram(request)
            windowController.presentWindow(title: executable)
            logger.info("Launched \(executable)")
        } catch {
            logger.error("Failed to launch program: \(error)")
            showVMError(
                title: "Could not launch \(executable)",
                detail: error.localizedDescription,
                recovery: "Ensure the WinRunAgent service is running inside the Windows VM "
                    + "and the VM is fully booted."
            )
        }
    }

    /// Embedded mode for local development: boot VM and show console.
    @MainActor
    private func bootEmbedded(_ embedded: EmbeddedServiceProvider) async {
        do {
            fputs("[APP] Embedded boot: ensureVMRunning()...\n", stderr)
            _ = try await embedded.ensureVMRunning()
            fputs("[APP] Embedded boot complete — opening console window\n", stderr)
            consoleWindowController.showConsole(agentStatus: .checking)
            consoleWindowController.updateAgentStatus(.notFound)
        } catch {
            fputs("[APP] Embedded boot FAILED: \(error)\n", stderr)
            logger.error("Failed to start VM: \(error)")
            showVMError(
                title: "Could not start Windows VM",
                detail: error.localizedDescription,
                recovery: "Check that the Windows disk image exists and "
                    + "QEMU/swtpm are available in bundle or Homebrew."
            )
        }
    }

    private func showVMError(title: String, detail: String, recovery: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(detail)\n\n\(recovery)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                let exe = CommandLine.arguments.dropFirst().first
                    ?? "C:/Windows/System32/notepad.exe"
                await bootAndLaunch(exe)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Maintenance Boot

    @objc private func startMaintenanceBoot() {
        let diskPath = DiskImageConfiguration.defaultPath
        guard FileManager.default.fileExists(atPath: diskPath.path) else {
            let alert = NSAlert()
            alert.messageText = "No Windows VM Found"
            alert.informativeText = "Complete the setup wizard first to install Windows."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Start Maintenance Boot?"
        confirm.informativeText =
            "This will open a QEMU window to boot your Windows VM interactively. "
            + "Use this to install software, drivers, or the WinRunAgent.\n\n"
            + "The VM will have network access for downloads."
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "Start QEMU")
        confirm.addButton(withTitle: "Cancel")

        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let appSupportDir = diskPath.deletingLastPathComponent()
        let virtioISO = QEMUInstallHelper.findVirtIOISO(appSupportDir: appSupportDir)

        do {
            let result = try QEMUInstallHelper.launchMaintenanceVM(
                diskImagePath: diskPath,
                virtioISOPath: virtioISO
            )
            logger.info("Maintenance QEMU launched (pid \(result.process.processIdentifier))")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Start Maintenance Boot"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Console

    @objc private func openConsole() {
        Task { @MainActor in
            consoleWindowController.showConsole(agentStatus: .notFound)
        }
    }

    // MARK: - About / Settings / Help

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "WinRun"
        alert.informativeText = "Run Windows applications seamlessly on macOS.\n\nVersion 1.0"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showSettings() {
        settingsController.showSettings()
    }

    @objc private func showHelp() {
        if let url = URL(string: "https://github.com/winrun/winrun") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Entry Point

@main
struct WinRunAppMain {
    static func main() {
        if #available(macOS 13, *) {
            let app = NSApplication.shared
            let delegate = WinRunApplicationDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            delegate.start(arguments: CommandLine.arguments)
            app.run()
        } else {
            print("WinRun requires macOS 13 or newer.")
        }
    }
}
