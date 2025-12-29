import AppKit
import Foundation
import WinRunShared

/// Manages the WinRun settings/preferences window with tabbed categories.
///
/// Use the shared `SettingsWindowController.shared` instance to show and manage
/// the settings window. The controller ensures only one settings window is open
/// at a time, following macOS conventions.
@available(macOS 13, *)
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Shared singleton instance for the settings window.
    public static let shared = SettingsWindowController()

    /// The underlying settings window (nil when not shown).
    private var window: NSWindow?

    /// Tab view controller managing settings categories.
    private var tabViewController: NSTabViewController?

    /// Configuration store for persisting settings.
    private let configStore: ConfigStore

    /// Logger for settings operations.
    private let logger: Logger

    // MARK: - Settings Tabs

    /// Represents the available settings tab categories.
    public enum SettingsTab: String, CaseIterable {
        case streaming = "Streaming"

        var icon: NSImage? {
            switch self {
            case .streaming:
                return NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "Streaming")
            }
        }

        var toolTip: String {
            switch self {
            case .streaming:
                return "Configure frame streaming and buffer settings"
            }
        }
    }

    // MARK: - Initialization

    /// Creates a settings window controller.
    /// - Parameters:
    ///   - configStore: Configuration store for persistence (defaults to shared store).
    ///   - logger: Logger instance for diagnostics.
    public init(
        configStore: ConfigStore = ConfigStore(),
        logger: Logger = StandardLogger(subsystem: "WinRunApp.Settings")
    ) {
        self.configStore = configStore
        self.logger = logger
        super.init()
    }

    // MARK: - Public API

    /// Shows the settings window, creating it if necessary.
    ///
    /// If the window already exists, it is brought to the front.
    /// The window restores its last position and selected tab from preferences.
    public func showSettings() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = createSettingsWindow()
        self.window = newWindow

        restoreWindowState(newWindow)
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        logger.debug("Settings window opened")
    }

    /// Closes the settings window if open.
    public func closeSettings() {
        window?.close()
    }

    /// Returns true if the settings window is currently visible.
    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// The currently selected settings tab.
    public var selectedTab: SettingsTab? {
        get {
            guard let tabViewController = tabViewController else { return nil }
            let index = tabViewController.selectedTabViewItemIndex
            guard index >= 0 && index < SettingsTab.allCases.count else { return nil }
            return SettingsTab.allCases[index]
        }
        set {
            guard let tab = newValue,
                  let index = SettingsTab.allCases.firstIndex(of: tab) else { return }
            tabViewController?.selectedTabViewItemIndex = index
        }
    }

    // MARK: - Window Creation

    private func createSettingsWindow() -> NSWindow {
        let tabViewController = createTabViewController()
        self.tabViewController = tabViewController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "WinRun Settings"
        window.contentViewController = tabViewController
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        // Set window autosave name for automatic frame restoration
        window.setFrameAutosaveName("WinRunSettingsWindow")

        return window
    }

    private func createTabViewController() -> NSTabViewController {
        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar

        // Add tab items for each category
        for tab in SettingsTab.allCases {
            let tabItem = createTabViewItem(for: tab)
            tabViewController.addTabViewItem(tabItem)
        }

        return tabViewController
    }

    private func createTabViewItem(for tab: SettingsTab) -> NSTabViewItem {
        let viewController = createViewController(for: tab)

        let tabItem = NSTabViewItem(viewController: viewController)
        tabItem.label = tab.rawValue
        tabItem.image = tab.icon
        tabItem.toolTip = tab.toolTip

        return tabItem
    }

    private func createViewController(for tab: SettingsTab) -> NSViewController {
        switch tab {
        case .streaming:
            let controller = StreamingSettingsViewController(
                configStore: configStore,
                logger: logger
            )
            controller.onFrameBufferModeChanged = { [weak self] mode in
                self?.logger.info("Frame buffer mode updated: \(mode.rawValue)")
                // Future: Send mode change to guest agent via control channel
            }
            return controller
        }
    }

    // MARK: - Window State Persistence

    private func restoreWindowState(_ window: NSWindow) {
        // Restore selected tab from user defaults
        if let savedTab = UserDefaults.standard.string(forKey: "SettingsSelectedTab"),
           let tab = SettingsTab(rawValue: savedTab),
           let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabViewController?.selectedTabViewItemIndex = index
            logger.debug("Restored settings tab: \(savedTab)")
        }
    }

    private func saveWindowState() {
        // Save selected tab
        if let tab = selectedTab {
            UserDefaults.standard.set(tab.rawValue, forKey: "SettingsSelectedTab")
            logger.debug("Saved settings tab: \(tab.rawValue)")
        }
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        saveWindowState()
        window = nil
        tabViewController = nil
        logger.debug("Settings window closed")
    }
}
