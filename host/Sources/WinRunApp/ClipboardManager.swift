import Foundation
import AppKit
import WinRunShared
import WinRunSpiceBridge

// MARK: - ClipboardManagerDelegate

protocol ClipboardManagerDelegate: AnyObject {
    func clipboardManager(_ manager: ClipboardManager, didDetectHostClipboardChange clipboard: ClipboardData)
}

// MARK: - ClipboardManager

/// Manages clipboard synchronization between macOS and Windows guest.
///
/// This class monitors the macOS pasteboard for changes and notifies the delegate
/// when the host clipboard changes, enabling synchronization with the Windows guest.
/// It also handles setting the macOS clipboard from guest clipboard data.
///
/// ## Architecture
///
/// macOS does not provide a push notification for pasteboard changes. Instead of
/// inefficient timer-based polling, this implementation uses an event-driven approach:
///
/// 1. **Application activation** - Checks clipboard when the app becomes active
///    (the most common clipboard change scenario is copy from another app → switch back)
/// 2. **Window focus** - Checks clipboard when the window becomes key
/// 3. **Explicit checks** - Provides `checkForChanges()` for controllers to call on demand
///
/// This eliminates unnecessary CPU wake-ups while providing responsive clipboard sync.
final class ClipboardManager {
    weak var delegate: ClipboardManagerDelegate?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var sequenceNumber: UInt64 = 0
    private var isSettingFromGuest = false
    private var isMonitoring = false
    private var notificationObserver: NSObjectProtocol?

    // MARK: - Monitoring

    /// Start monitoring for clipboard changes using event-based detection.
    ///
    /// This observes application activation events rather than polling on a timer.
    /// Call `checkForChanges()` explicitly when the window becomes key for
    /// additional responsiveness.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastChangeCount = pasteboard.changeCount

        // Observe application activation - the primary event for clipboard changes
        // (user copies in another app, then switches back to WinRun)
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    /// Stop monitoring for clipboard changes.
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
    }

    /// Check for clipboard changes and notify delegate if changed.
    ///
    /// Call this method when:
    /// - The window becomes key (`windowDidBecomeKey`)
    /// - Before performing paste operations
    /// - Any other event that might indicate clipboard activity
    ///
    /// This is safe to call frequently as it only performs a lightweight
    /// comparison of the pasteboard's change count.
    func checkForChanges() {
        guard !isSettingFromGuest else { return }

        let currentCount = pasteboard.changeCount
        if currentCount != lastChangeCount {
            lastChangeCount = currentCount

            // Clipboard changed - notify delegate
            if let clipboard = getCurrentClipboardData() {
                delegate?.clipboardManager(self, didDetectHostClipboardChange: clipboard)
            }
        }
    }

    // MARK: - Reading Clipboard

    private func getCurrentClipboardData() -> ClipboardData? {
        sequenceNumber += 1

        // Try to get text first (most common)
        if let string = pasteboard.string(forType: .string) {
            return ClipboardData.text(string, sequenceNumber: sequenceNumber)
        }

        // Try RTF
        if let rtfData = pasteboard.data(forType: .rtf) {
            return ClipboardData(format: .rtf, data: rtfData, sequenceNumber: sequenceNumber)
        }

        // Try HTML
        if let htmlData = pasteboard.data(forType: .html) {
            return ClipboardData(format: .html, data: htmlData, sequenceNumber: sequenceNumber)
        }

        // Try PNG
        if let pngData = pasteboard.data(forType: .png) {
            return ClipboardData(format: .png, data: pngData, sequenceNumber: sequenceNumber)
        }

        // Try TIFF
        if let tiffData = pasteboard.data(forType: .tiff) {
            return ClipboardData(format: .tiff, data: tiffData, sequenceNumber: sequenceNumber)
        }

        return nil
    }

    // MARK: - Writing Clipboard

    /// Set the macOS pasteboard from guest clipboard data
    func setFromGuest(_ clipboard: ClipboardData) {
        isSettingFromGuest = true
        defer {
            isSettingFromGuest = false
            lastChangeCount = pasteboard.changeCount
        }

        pasteboard.clearContents()

        switch clipboard.format {
        case .plainText:
            if let text = clipboard.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .rtf:
            pasteboard.setData(clipboard.data, forType: .rtf)
        case .html:
            pasteboard.setData(clipboard.data, forType: .html)
        case .png:
            pasteboard.setData(clipboard.data, forType: .png)
        case .tiff:
            pasteboard.setData(clipboard.data, forType: .tiff)
        case .fileUrl:
            if let urlString = String(data: clipboard.data, encoding: .utf8),
               let url = URL(string: urlString) {
                pasteboard.writeObjects([url as NSURL])
            }
        }
    }
}
