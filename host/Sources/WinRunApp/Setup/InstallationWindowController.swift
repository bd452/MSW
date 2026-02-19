import AppKit
import Foundation
#if canImport(Virtualization)
import Virtualization
#endif

/// Window controller that displays the VM's screen during Windows installation.
///
/// Uses `VZVirtualMachineView` to provide a native view of the VM's graphics output,
/// allowing users to see and interact with the Windows Setup GUI.
@available(macOS 13, *)
public final class InstallationWindowController: NSObject {
    private var window: NSWindow?
    #if canImport(Virtualization)
    private var vmView: VZVirtualMachineView?
    #endif

    /// Shows the installation window for the given VM.
    /// - Parameter vm: The virtual machine to display
    @MainActor
    public func showWindow(for vm: Any) {
        #if canImport(Virtualization)
        guard let virtualMachine = vm as? VZVirtualMachine else {
            return
        }

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = virtualMachine
        vmView.capturesSystemKeys = true
        vmView.autoresizingMask = [.width, .height]
        self.vmView = vmView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Windows Installation"
        window.backgroundColor = .windowBackgroundColor
        window.contentView = vmView
        window.center()

        // Ensure window is properly displayed
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Set minimum size to prevent too-small windows
        window.minSize = NSSize(width: 800, height: 600)

        self.window = window

        // Log for debugging
        print("[InstallationWindow] Window shown, VM state: \(virtualMachine.state.rawValue)")
        #endif
    }

    /// Closes the installation window.
    @MainActor
    public func closeWindow() {
        window?.close()
        window = nil
        #if canImport(Virtualization)
        vmView?.virtualMachine = nil
        vmView = nil
        #endif
    }

    /// Updates the window title with installation progress.
    @MainActor
    public func updateTitle(_ title: String) {
        window?.title = title
    }
}

/// Singleton accessor for the installation window during setup.
@available(macOS 13, *)
public enum InstallationWindow {
    private static var controller: InstallationWindowController?

    /// Shows the installation window for the given VM.
    @MainActor
    public static func show(for vm: Any) {
        if controller == nil {
            controller = InstallationWindowController()
        }
        controller?.showWindow(for: vm)
    }

    /// Closes the installation window.
    @MainActor
    public static func close() {
        controller?.closeWindow()
        controller = nil
    }

    /// Updates the window title.
    @MainActor
    public static func updateTitle(_ title: String) {
        controller?.updateTitle(title)
    }
}
