import Foundation
import AppKit
import MetalKit
import WinRunShared
import WinRunXPC
import WinRunSpiceBridge

@available(macOS 13, *)
final class WinRunWindowController: NSObject, SpiceWindowStreamDelegate, MetalContentViewInputDelegate {
    private var window: NSWindow?
    private let renderer: SpiceFrameRenderer
    private var metalContentView: MetalContentView?
    private let stream: SpiceWindowStream
    private let logger: Logger
    
    /// Current metadata from the Spice stream
    private var currentMetadata: WindowMetadata?
    
    /// Clipboard synchronization
    private let clipboardManager: ClipboardManager

    override init() {
        self.logger = StandardLogger(subsystem: "WinRunWindowController")
        self.stream = SpiceWindowStream(configuration: SpiceStreamConfiguration.environmentDefault())
        self.renderer = SpiceFrameRenderer()
        self.clipboardManager = ClipboardManager()
        super.init()
        stream.delegate = self
        clipboardManager.delegate = self
    }

    func presentWindow(title: String) {
        let contentRect = NSRect(x: 100, y: 100, width: 800, height: 600)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 320, height: 240)
        window.delegate = self
        
        // Create Metal content view for GPU-accelerated frame rendering
        let metalView = MetalContentView(frame: contentRect, renderer: renderer)
        metalView.inputDelegate = self
        window.contentView = metalView
        self.metalContentView = metalView
        
        // Make window accept mouse moved events
        window.acceptsMouseMovedEvents = true
        
        // Center window on screen
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        
        // Start clipboard monitoring
        clipboardManager.startMonitoring()
        
        logger.info("Window created with Metal rendering layer and input forwarding")
        stream.connect(toWindowID: 0)
    }
    
    // MARK: - MetalContentViewInputDelegate
    
    func metalContentView(_ view: MetalContentView, didReceiveMouseEvent event: MouseInputEvent) {
        stream.sendMouseEvent(event)
    }
    
    func metalContentView(_ view: MetalContentView, didReceiveKeyboardEvent event: KeyboardInputEvent) {
        stream.sendKeyboardEvent(event)
    }
    
    func metalContentView(_ view: MetalContentView, didReceiveDragDropEvent event: DragDropEvent) {
        stream.sendDragDropEvent(event)
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateFrame frame: Data) {
        guard let metalView = metalContentView else { return }
        
        // Use metadata dimensions if available, otherwise estimate from frame size
        let width: Int
        let height: Int
        let scaleFactor: CGFloat
        
        if let metadata = currentMetadata {
            width = Int(metadata.frame.width)
            height = Int(metadata.frame.height)
            scaleFactor = metadata.scaleFactor
        } else {
            // Estimate dimensions assuming BGRA (4 bytes per pixel) and 16:9 aspect ratio
            let pixelCount = frame.count / 4
            let estimatedWidth = Int(sqrt(Double(pixelCount) * 16.0 / 9.0))
            width = estimatedWidth
            height = pixelCount / max(estimatedWidth, 1)
            scaleFactor = 1.0
        }
        
        metalView.updateFrame(
            pixelData: frame,
            width: width,
            height: height,
            guestScaleFactor: scaleFactor
        )
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata) {
        currentMetadata = metadata
        
        guard let window = window else { return }
        
        // Update window title
        window.title = metadata.title
        
        // Optionally resize window to match guest frame size (scaled for Retina)
        if metadata.frame.width > 0 && metadata.frame.height > 0 {
            let backingScale = window.backingScaleFactor
            let pointWidth = metadata.frame.width / backingScale
            let pointHeight = metadata.frame.height / backingScale
            
            // Only resize if dimensions changed significantly
            let currentSize = window.contentView?.frame.size ?? .zero
            let widthDelta = abs(currentSize.width - pointWidth)
            let heightDelta = abs(currentSize.height - pointHeight)
            
            if widthDelta > 10 || heightDelta > 10 {
                let newContentSize = NSSize(width: pointWidth, height: pointHeight)
                window.setContentSize(newContentSize)
                logger.debug("Resized window to \(Int(pointWidth))x\(Int(pointHeight)) points")
            }
        }
        
        // Update resizable style based on metadata
        if metadata.isResizable {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
    }

    func windowStreamDidClose(_ stream: SpiceWindowStream) {
        logger.info("Spice stream closed, closing window")
        clipboardManager.stopMonitoring()
        window?.close()
        metalContentView?.clearFrame()
    }
    
    func windowStream(_ stream: SpiceWindowStream, didReceiveClipboard clipboard: ClipboardData) {
        // Update macOS pasteboard with clipboard data from Windows guest
        clipboardManager.setFromGuest(clipboard)
    }
}

// MARK: - NSWindowDelegate

@available(macOS 13, *)
extension WinRunWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Disconnect the stream when window is closed by user
        clipboardManager.stopMonitoring()
        stream.disconnect()
    }
    
    func windowDidChangeBackingProperties(_ notification: Notification) {
        // Handle display changes (e.g., moving between Retina and non-Retina displays)
        guard let window = notification.object as? NSWindow else { return }
        let newScale = window.backingScaleFactor
        logger.debug("Window backing scale factor changed to \(newScale)")
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Request clipboard from guest when window becomes active
        stream.requestClipboard(format: .plainText)
    }
}

// MARK: - ClipboardManagerDelegate

@available(macOS 13, *)
extension WinRunWindowController: ClipboardManagerDelegate {
    func clipboardManager(_ manager: ClipboardManager, didDetectHostClipboardChange clipboard: ClipboardData) {
        // Send host clipboard to Windows guest
        stream.sendClipboard(clipboard)
    }
}

@available(macOS 13, *)
final class WinRunApplicationDelegate: NSObject, NSApplicationDelegate {
    private let daemonClient = WinRunDaemonClient()
    private let logger = StandardLogger(subsystem: "WinRunApp")
    private let windowController = WinRunWindowController()

    func start(arguments: [String]) {
        setupMenuBar()
        
        Task {
            do {
                _ = try await daemonClient.ensureVMRunning()
                let executable = arguments.dropFirst().first ?? "C:/Windows/System32/notepad.exe"
                let request = ProgramLaunchRequest(windowsPath: executable)
                try await daemonClient.executeProgram(request)
                windowController.presentWindow(title: executable)
            } catch {
                logger.error("Failed to start Windows program: \(error)")
            }
        }
    }
    
    // MARK: - Menu Bar Setup
    
    private func setupMenuBar() {
        let mainMenu = NSMenu()
        
        // Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        
        appMenu.addItem(NSMenuItem(title: "About WinRun", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide WinRun", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit WinRun", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        
        // Edit Menu (with clipboard integration)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        
        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        
        // Help Menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        
        helpMenu.addItem(NSMenuItem(title: "WinRun Help", action: #selector(showHelp), keyEquivalent: "?"))
        
        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
        NSApplication.shared.helpMenu = helpMenu
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "WinRun"
        alert.informativeText = "Run Windows applications seamlessly on macOS.\n\nVersion 1.0"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc private func showHelp() {
        if let url = URL(string: "https://github.com/winrun/winrun") {
            NSWorkspace.shared.open(url)
        }
    }
}

@main
struct WinRunAppMain {
    static func main() {
        if #available(macOS 13, *) {
            let delegate = WinRunApplicationDelegate()
            delegate.start(arguments: CommandLine.arguments)
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.run()
        } else {
            print("WinRun requires macOS 13 or newer.")
        }
    }
}
