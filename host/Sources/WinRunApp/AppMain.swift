import Foundation
import AppKit
import MetalKit
import WinRunShared
import WinRunXPC
import WinRunSpiceBridge

@available(macOS 13, *)
final class WinRunWindowController: NSObject, SpiceWindowStreamDelegate {
    private var window: NSWindow?
    private let renderer: SpiceFrameRenderer
    private var metalContentView: MetalContentView?
    private let stream: SpiceWindowStream
    private let logger: Logger
    
    /// Current metadata from the Spice stream
    private var currentMetadata: WindowMetadata?

    override init() {
        self.logger = StandardLogger(subsystem: "WinRunWindowController")
        self.stream = SpiceWindowStream(configuration: SpiceStreamConfiguration.environmentDefault())
        self.renderer = SpiceFrameRenderer()
        super.init()
        stream.delegate = self
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
        window.contentView = metalView
        self.metalContentView = metalView
        
        // Center window on screen
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        
        logger.info("Window created with Metal rendering layer")
        stream.connect(toWindowID: 0)
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
        window?.close()
        metalContentView?.clearFrame()
    }
}

// MARK: - NSWindowDelegate

@available(macOS 13, *)
extension WinRunWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Disconnect the stream when window is closed by user
        stream.disconnect()
    }
    
    func windowDidChangeBackingProperties(_ notification: Notification) {
        // Handle display changes (e.g., moving between Retina and non-Retina displays)
        guard let window = notification.object as? NSWindow else { return }
        let newScale = window.backingScaleFactor
        logger.debug("Window backing scale factor changed to \(newScale)")
    }
}

@available(macOS 13, *)
final class WinRunApplicationDelegate: NSObject {
    private let daemonClient = WinRunDaemonClient()
    private let logger = StandardLogger(subsystem: "WinRunApp")
    private let windowController = WinRunWindowController()

    func start(arguments: [String]) {
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
