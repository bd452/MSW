import Foundation

/// Abstraction over the VM management backend.
///
/// Production builds talk to `winrund` via XPC (`WinRunDaemonClient`).
/// Debug/development builds run the VM in-process (`EmbeddedServiceProvider`).
public protocol VMServiceProvider: AnyObject {
    func ensureVMRunning() async throws -> VMState
    func executeProgram(_ request: ProgramLaunchRequest) async throws
    func status() async throws -> VMState
    func suspendIfIdle() async throws
    func stopVM() async throws -> VMState
    func listSessions() async throws -> GuestSessionList
    func closeSession(_ sessionId: String) async throws
    func listShortcuts() async throws -> WindowsShortcutList
    func syncShortcuts(to destinationPath: String) async throws -> ShortcutSyncResult
}
