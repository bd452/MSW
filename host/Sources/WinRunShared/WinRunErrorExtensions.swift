import Foundation

// MARK: - Error Wrapping Helpers

extension WinRunError {
    /// Wraps an arbitrary error as an internal WinRunError.
    public static func wrap(_ error: Error, context: String? = nil) -> WinRunError {
        if let winRunError = error as? WinRunError {
            return winRunError
        }
        let message =
            context.map { "\($0): \(error.localizedDescription)" }
            ?? error.localizedDescription
        return .internalError(message: message)
    }
}

// MARK: - Error Code (for bridging)

extension WinRunError {
    /// Integer error code for bridging to C APIs or XPC.
    public var code: Int {
        switch self {
        case .vmNotInitialized: return 1001
        case .vmAlreadyStopped: return 1002
        case .vmOperationTimeout: return 1003
        case .vmSnapshotFailed: return 1004
        case .virtualizationUnavailable: return 1005

        case .configReadFailed: return 2001
        case .configWriteFailed: return 2002
        case .configInvalid: return 2003
        case .configSchemaUnsupported: return 2004
        case .configMissingValue: return 2005

        case .spiceConnectionFailed: return 3001
        case .spiceDisconnected: return 3002
        case .spiceSharedMemoryUnavailable: return 3003
        case .spiceAuthenticationFailed: return 3004

        case .daemonUnreachable: return 4001
        case .xpcConnectionRejected: return 4002
        case .xpcThrottled: return 4003
        case .xpcUnauthorized: return 4004

        case .launchFailed: return 5001
        case .invalidExecutable: return 5002
        case .programExitedWithError: return 5003

        case .launcherAlreadyExists: return 6001
        case .launcherCreationFailed: return 6002
        case .launcherIconMissing: return 6003

        case .isoMountFailed: return 7001
        case .isoInvalid: return 7002
        case .isoArchitectureUnsupported: return 7003
        case .isoVersionWarning: return 7004
        case .isoMetadataParseFailed: return 7005
        case .diskCreationFailed: return 7006
        case .diskAlreadyExists: return 7007
        case .diskInvalidSize: return 7008
        case .diskInsufficientSpace: return 7009

        case .cancelled: return 9001
        case .internalError: return 9002
        case .notSupported: return 9003
        }
    }
}

// MARK: - Equatable

extension WinRunError: Equatable {
    public static func == (lhs: WinRunError, rhs: WinRunError) -> Bool {
        // Compare by code and domain for equality (ignoring associated value details)
        lhs.code == rhs.code
    }
}
