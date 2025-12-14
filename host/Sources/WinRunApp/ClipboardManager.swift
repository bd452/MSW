import Foundation
import AppKit
import WinRunShared

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
final class ClipboardManager {
    weak var delegate: ClipboardManagerDelegate?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var monitorTimer: Timer?
    private var sequenceNumber: UInt64 = 0
    private var isSettingFromGuest = false

    // MARK: - Monitoring

    func startMonitoring() {
        lastChangeCount = pasteboard.changeCount

        // Monitor pasteboard changes periodically
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func checkForChanges() {
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
