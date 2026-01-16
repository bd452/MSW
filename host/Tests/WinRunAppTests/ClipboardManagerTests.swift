import Foundation
import WinRunShared
import WinRunSpiceBridge
import XCTest

@testable import WinRunApp

@available(macOS 13, *)
final class ClipboardManagerTests: XCTestCase {
    private var clipboardManager: ClipboardManager!
    private var mockDelegate: MockClipboardManagerDelegate!

    override func setUp() {
        super.setUp()
        clipboardManager = ClipboardManager()
        mockDelegate = MockClipboardManagerDelegate()
        clipboardManager.delegate = mockDelegate
    }

    override func tearDown() {
        clipboardManager.stopMonitoring()
        clipboardManager = nil
        mockDelegate = nil
        super.tearDown()
    }

    // MARK: - Monitoring Lifecycle Tests

    func testStartMonitoringIsIdempotent() {
        // Starting monitoring multiple times should not register multiple observers
        clipboardManager.startMonitoring()
        clipboardManager.startMonitoring()
        clipboardManager.startMonitoring()

        // Stop should work correctly (no crashes from over-releasing)
        clipboardManager.stopMonitoring()
        clipboardManager.stopMonitoring()
    }

    func testStopMonitoringWithoutStartDoesNotCrash() {
        // Stopping without starting should be safe
        clipboardManager.stopMonitoring()
    }

    // MARK: - Change Detection Tests

    func testCheckForChangesDoesNotNotifyWhenUnchanged() {
        clipboardManager.startMonitoring()

        // Check without any clipboard changes
        clipboardManager.checkForChanges()
        clipboardManager.checkForChanges()
        clipboardManager.checkForChanges()

        // Should not notify since clipboard hasn't changed
        // Note: The first check after startMonitoring captures the baseline
        XCTAssertEqual(mockDelegate.changeNotificationCount, 0)
    }

    func testCheckForChangesCanBeCalledBeforeStartMonitoring() {
        // Should be safe to call checkForChanges before startMonitoring
        clipboardManager.checkForChanges()
    }

    // MARK: - Delegate Tests

    func testDelegateIsWeaklyHeld() {
        var strongDelegate: MockClipboardManagerDelegate? = MockClipboardManagerDelegate()
        weak var weakDelegate = strongDelegate

        clipboardManager.delegate = strongDelegate
        strongDelegate = nil

        // Delegate should be released
        XCTAssertNil(weakDelegate)
    }

    // MARK: - Guest Clipboard Setting Tests

    func testSetFromGuestWithTextFormat() {
        let clipboard = ClipboardData.text("Hello from Windows", sequenceNumber: 1)

        // Should not crash and should update the pasteboard
        clipboardManager.setFromGuest(clipboard)
    }

    func testSetFromGuestDoesNotTriggerChangeNotification() {
        clipboardManager.startMonitoring()

        let clipboard = ClipboardData.text("Test content", sequenceNumber: 1)
        clipboardManager.setFromGuest(clipboard)

        // Give the change count time to update
        clipboardManager.checkForChanges()

        // Setting from guest should not trigger a notification back to delegate
        // (prevents echo/feedback loops)
        XCTAssertEqual(mockDelegate.changeNotificationCount, 0)
    }

    // MARK: - Integration Tests

    func testClipboardChangeIntegration() {
        clipboardManager.startMonitoring()

        // Simulate what happens when app becomes active after user copied in another app:
        // 1. The changeCount will be different from what we cached
        // 2. checkForChanges() is called (by app activation or window focus)
        // 3. If changed, delegate should be notified

        // We can't easily simulate clipboard changes from outside,
        // but we can verify the flow works by setting content ourselves
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)

        // Clear and set new content (simulating external change)
        pasteboard.clearContents()
        pasteboard.setString("External app copied this", forType: .string)

        // Now check for changes - should detect the change
        clipboardManager.checkForChanges()

        // Verify delegate was notified
        XCTAssertEqual(mockDelegate.changeNotificationCount, 1)
        XCTAssertNotNil(mockDelegate.lastClipboardData)

        // Restore original content if there was any
        if let original = originalContent {
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
        }
    }

    func testApplicationActivationNotificationTriggersCheck() {
        clipboardManager.startMonitoring()

        // Simulate clipboard change
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Changed content", forType: .string)

        // Post the application activation notification
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )

        // Give the notification time to be processed on main queue
        let expectation = expectation(description: "Notification processed")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Delegate should have been notified of the change
        XCTAssertEqual(mockDelegate.changeNotificationCount, 1)
    }
}

// MARK: - Mock Delegate

@available(macOS 13, *)
private final class MockClipboardManagerDelegate: ClipboardManagerDelegate {
    var changeNotificationCount = 0
    var lastClipboardData: ClipboardData?

    func clipboardManager(_ manager: ClipboardManager, didDetectHostClipboardChange clipboard: ClipboardData) {
        changeNotificationCount += 1
        lastClipboardData = clipboard
    }
}
