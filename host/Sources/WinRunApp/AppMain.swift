import AppKit
import Foundation
import WinRunShared
import WinRunXPC

/// Application delegate managing WinRun app lifecycle and menu bar.
@available(macOS 13, *)
final class WinRunApplicationDelegate: NSObject, NSApplicationDelegate {
    private let daemonClient = WinRunDaemonClient()
    private let logger = StandardLogger(subsystem: "WinRunApp")
    private let windowController = WinRunWindowController()
    private var setupFlowController: SetupFlowController?
    private let settingsController = SettingsWindowController.shared

    func start(arguments: [String]) {
        setupMenuBar()

        let preflight = ProvisioningPreflight.evaluate()
        let setupFlowController = SetupFlowController(preflight: preflight)
        self.setupFlowController = setupFlowController
        setupFlowController.routeToSetupOrNormalOperation { [self] in
            Task {
                do {
                    _ = try await self.daemonClient.ensureVMRunning()
                    let executable = arguments.dropFirst().first ?? "C:/Windows/System32/notepad.exe"
                    let request = ProgramLaunchRequest(windowsPath: executable)
                    try await self.daemonClient.executeProgram(request)
                    self.windowController.presentWindow(title: executable)
                } catch {
                    self.logger.error("Failed to start Windows program: \(error)")
                }
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
