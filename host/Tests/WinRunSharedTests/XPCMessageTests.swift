import XCTest

@testable import WinRunShared

// MARK: - XPC Message Serialization Tests

final class XPCMessageSerializationTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - ProgramLaunchRequest Tests

    func testProgramLaunchRequestRoundTrip() throws {
        let request = ProgramLaunchRequest(
            windowsPath: "C:\\Program Files\\App\\app.exe",
            arguments: ["--verbose", "-c", "config.ini"],
            workingDirectory: "C:\\Users\\Admin\\Documents"
        )

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(ProgramLaunchRequest.self, from: data)

        XCTAssertEqual(decoded.windowsPath, request.windowsPath)
        XCTAssertEqual(decoded.arguments, request.arguments)
        XCTAssertEqual(decoded.workingDirectory, request.workingDirectory)
    }

    func testProgramLaunchRequestMinimal() throws {
        let request = ProgramLaunchRequest(windowsPath: "notepad.exe")

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(ProgramLaunchRequest.self, from: data)

        XCTAssertEqual(decoded.windowsPath, "notepad.exe")
        XCTAssertTrue(decoded.arguments.isEmpty)
        XCTAssertNil(decoded.workingDirectory)
    }

    func testProgramLaunchRequestWithSpecialCharacters() throws {
        let request = ProgramLaunchRequest(
            windowsPath: "C:\\Program Files (x86)\\My App\\app.exe",
            arguments: ["--path=\"C:\\Temp\\file name.txt\"", "--flag"]
        )

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(ProgramLaunchRequest.self, from: data)

        XCTAssertEqual(decoded.windowsPath, request.windowsPath)
        XCTAssertEqual(decoded.arguments, request.arguments)
    }

    // MARK: - VMState Tests

    func testVMStateRoundTrip() throws {
        let state = VMState(status: .running, uptime: 3600.5, activeSessions: 3)

        let data = try encoder.encode(state)
        let decoded = try decoder.decode(VMState.self, from: data)

        XCTAssertEqual(decoded.status, .running)
        XCTAssertEqual(decoded.uptime, 3600.5)
        XCTAssertEqual(decoded.activeSessions, 3)
    }

    func testAllVMStatusValuesEncodable() throws {
        let allStatuses: [VMStatus] = [
            .stopped, .starting, .running, .suspending, .suspended, .stopping,
        ]

        for status in allStatuses {
            let state = VMState(status: status, uptime: 0, activeSessions: 0)
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(VMState.self, from: data)
            XCTAssertEqual(decoded.status, status, "Status \(status) should round-trip correctly")
        }
    }

    // MARK: - GuestSession Tests

    func testGuestSessionRoundTrip() throws {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let session = GuestSession(
            id: "session-123",
            windowsPath: "C:\\Windows\\notepad.exe",
            windowTitle: "Untitled - Notepad",
            processId: 1234,
            startedAt: startDate
        )

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(GuestSession.self, from: data)

        XCTAssertEqual(decoded.id, "session-123")
        XCTAssertEqual(decoded.windowsPath, session.windowsPath)
        XCTAssertEqual(decoded.windowTitle, "Untitled - Notepad")
        XCTAssertEqual(decoded.processId, 1234)
        XCTAssertEqual(
            decoded.startedAt.timeIntervalSince1970, startDate.timeIntervalSince1970, accuracy: 1)
    }

    func testGuestSessionListRoundTrip() throws {
        let sessions = GuestSessionList(sessions: [
            GuestSession(
                id: "s1",
                windowsPath: "notepad.exe",
                windowTitle: "Document.txt",
                processId: 100,
                startedAt: Date()
            ),
            GuestSession(
                id: "s2",
                windowsPath: "calc.exe",
                windowTitle: "Calculator",
                processId: 200,
                startedAt: Date()
            ),
        ])

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(sessions)
        let decoded = try decoder.decode(GuestSessionList.self, from: data)

        XCTAssertEqual(decoded.sessions.count, 2)
        XCTAssertEqual(decoded.sessions[0].id, "s1")
        XCTAssertEqual(decoded.sessions[1].id, "s2")
    }

    func testGuestSessionListEmpty() throws {
        let sessions = GuestSessionList(sessions: [])

        let data = try encoder.encode(sessions)
        let decoded = try decoder.decode(GuestSessionList.self, from: data)

        XCTAssertTrue(decoded.sessions.isEmpty)
    }

    // MARK: - WindowsShortcut Tests

    func testWindowsShortcutRoundTrip() throws {
        let shortcut = WindowsShortcut(
            shortcutPath: "C:\\Users\\Admin\\Desktop\\My App.lnk",
            targetPath: "C:\\Program Files\\My App\\app.exe",
            displayName: "My App",
            iconPath: "C:\\Program Files\\My App\\app.ico",
            arguments: "--start-minimized",
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(shortcut)
        let decoded = try decoder.decode(WindowsShortcut.self, from: data)

        XCTAssertEqual(decoded.shortcutPath, shortcut.shortcutPath)
        XCTAssertEqual(decoded.targetPath, shortcut.targetPath)
        XCTAssertEqual(decoded.displayName, "My App")
        XCTAssertEqual(decoded.iconPath, shortcut.iconPath)
        XCTAssertEqual(decoded.arguments, "--start-minimized")
        XCTAssertEqual(decoded.id, shortcut.shortcutPath)  // id is derived from shortcutPath
    }

    func testWindowsShortcutMinimal() throws {
        let shortcut = WindowsShortcut(
            shortcutPath: "C:\\Users\\Desktop\\app.lnk",
            targetPath: "C:\\app.exe",
            displayName: "App"
        )

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(shortcut)
        let decoded = try decoder.decode(WindowsShortcut.self, from: data)

        XCTAssertEqual(decoded.displayName, "App")
        XCTAssertNil(decoded.iconPath)
        XCTAssertNil(decoded.arguments)
    }

    func testWindowsShortcutListRoundTrip() throws {
        let shortcuts = WindowsShortcutList(shortcuts: [
            WindowsShortcut(
                shortcutPath: "C:\\Desktop\\A.lnk",
                targetPath: "C:\\A.exe",
                displayName: "App A"
            ),
            WindowsShortcut(
                shortcutPath: "C:\\Desktop\\B.lnk",
                targetPath: "C:\\B.exe",
                displayName: "App B",
                iconPath: "C:\\B.ico"
            ),
        ])

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(shortcuts)
        let decoded = try decoder.decode(WindowsShortcutList.self, from: data)

        XCTAssertEqual(decoded.shortcuts.count, 2)
        XCTAssertEqual(decoded.shortcuts[0].displayName, "App A")
        XCTAssertEqual(decoded.shortcuts[1].displayName, "App B")
    }

    // MARK: - ShortcutSyncResult Tests

    func testShortcutSyncResultRoundTrip() throws {
        let result = ShortcutSyncResult(
            created: 5,
            skipped: 2,
            failed: 1,
            launcherPaths: [
                "/Users/test/Applications/WinRun Apps/App1.app",
                "/Users/test/Applications/WinRun Apps/App2.app",
            ]
        )

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ShortcutSyncResult.self, from: data)

        XCTAssertEqual(decoded.created, 5)
        XCTAssertEqual(decoded.skipped, 2)
        XCTAssertEqual(decoded.failed, 1)
        XCTAssertEqual(decoded.launcherPaths.count, 2)
    }

    func testShortcutSyncResultEmpty() throws {
        let result = ShortcutSyncResult(created: 0, skipped: 0, failed: 0, launcherPaths: [])

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ShortcutSyncResult.self, from: data)

        XCTAssertEqual(decoded.created, 0)
        XCTAssertTrue(decoded.launcherPaths.isEmpty)
    }

    // MARK: - VMMetricsSnapshot Tests

    func testVMMetricsSnapshotRoundTrip() throws {
        let metrics = VMMetricsSnapshot(
            event: "boot",
            uptimeSeconds: 3600,
            activeSessions: 2,
            totalSessions: 10,
            bootCount: 5,
            suspendCount: 3
        )

        let data = try encoder.encode(metrics)
        let decoded = try decoder.decode(VMMetricsSnapshot.self, from: data)

        XCTAssertEqual(decoded.event, "boot")
        XCTAssertEqual(decoded.uptimeSeconds, 3600)
        XCTAssertEqual(decoded.activeSessions, 2)
        XCTAssertEqual(decoded.totalSessions, 10)
        XCTAssertEqual(decoded.bootCount, 5)
        XCTAssertEqual(decoded.suspendCount, 3)
    }

    func testVMMetricsSnapshotDescription() {
        let metrics = VMMetricsSnapshot(
            event: "shutdown",
            uptimeSeconds: 7200.5,
            activeSessions: 0,
            totalSessions: 5,
            bootCount: 2,
            suspendCount: 1
        )

        let description = metrics.description

        XCTAssertTrue(description.contains("event=shutdown"))
        XCTAssertTrue(description.contains("uptime=7200.50s"))
        XCTAssertTrue(description.contains("activeSessions=0"))
        XCTAssertTrue(description.contains("boots=2"))
    }
}

// MARK: - XPC Data Contract Tests

final class XPCDataContractTests: XCTestCase {
    /// Tests that XPC messages have stable JSON keys for cross-process compatibility
    func testProgramLaunchRequestJSONKeys() throws {
        let request = ProgramLaunchRequest(
            windowsPath: "test.exe",
            arguments: ["arg"],
            workingDirectory: "C:\\"
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["windowsPath"], "windowsPath key required for protocol")
        XCTAssertNotNil(json?["arguments"], "arguments key required for protocol")
        XCTAssertNotNil(json?["workingDirectory"], "workingDirectory key required for protocol")
    }

    func testVMStateJSONKeys() throws {
        let state = VMState(status: .running, uptime: 100, activeSessions: 1)

        let data = try JSONEncoder().encode(state)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["status"], "status key required for protocol")
        XCTAssertNotNil(json?["uptime"], "uptime key required for protocol")
        XCTAssertNotNil(json?["activeSessions"], "activeSessions key required for protocol")
    }

    func testGuestSessionJSONKeys() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let session = GuestSession(
            id: "test",
            windowsPath: "test.exe",
            windowTitle: "Test",
            processId: 1,
            startedAt: Date()
        )

        let data = try encoder.encode(session)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["id"], "id key required for protocol")
        XCTAssertNotNil(json?["windowsPath"], "windowsPath key required for protocol")
        XCTAssertNotNil(json?["processId"], "processId key required for protocol")
        XCTAssertNotNil(json?["startedAt"], "startedAt key required for protocol")
    }

    func testWindowsShortcutJSONKeys() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let shortcut = WindowsShortcut(
            shortcutPath: "test.lnk",
            targetPath: "test.exe",
            displayName: "Test"
        )

        let data = try encoder.encode(shortcut)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["shortcutPath"], "shortcutPath key required for protocol")
        XCTAssertNotNil(json?["targetPath"], "targetPath key required for protocol")
        XCTAssertNotNil(json?["displayName"], "displayName key required for protocol")
        XCTAssertNotNil(json?["detectedAt"], "detectedAt key required for protocol")
    }
}
