import Foundation
#if canImport(AppKit)
import AppKit
#endif
import WinRunShared
import WinRunXPC
import WinRunSpiceBridge

@available(macOS 13, *)
final class WinRunWindowController: NSObject, SpiceWindowStreamDelegate {
    #if canImport(AppKit)
    private var window: NSWindow?
    #endif
    private let stream = SpiceWindowStream()

    override init() {
        super.init()
        stream.delegate = self
    }

    func presentWindow(title: String) {
        #if canImport(AppKit)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.makeKeyAndOrderFront(nil)
        self.window = window
        #else
        print(\"[WinRunApp] Would open window titled \\(title)\")
        #endif
        stream.connect(toWindowID: 0)
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateFrame frame: Data) {
        // Rendering handled by Metal layer in production. Here we just log frame reception.
        print("Received frame with size \(frame.count) bytes")
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata) {
        #if canImport(AppKit)
        window?.title = metadata.title
        #else
        print(\"[WinRunApp] Metadata update -> \\(metadata)\")
        #endif
    }

    func windowStreamDidClose(_ stream: SpiceWindowStream) {
        #if canImport(AppKit)
        window?.close()
        #else
        print(\"[WinRunApp] Stream closed\")
        #endif
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
            #if canImport(AppKit)
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.run()
            #else
            RunLoop.current.run()
            #endif
        } else {
            print(\"WinRun requires macOS 13 or newer.\")
        }
    }
}
