import Foundation

public enum SetupCompletionStatus: String, Codable, Sendable, Equatable {
    case inProgress = "in_progress"
    case completed = "completed"
}

public struct SetupCompletionMarker: Codable, Sendable, Equatable {
    public let status: SetupCompletionStatus
    public let diskImagePath: URL
    public let updatedAt: Date

    public init(
        status: SetupCompletionStatus,
        diskImagePath: URL,
        updatedAt: Date = Date()
    ) {
        self.status = status
        self.diskImagePath = diskImagePath
        self.updatedAt = updatedAt
    }
}

public struct SetupCompletionMarkerStore {
    public let markerURL: URL
    private let fileManager: FileManager

    public init(
        markerURL: URL = SetupCompletionMarkerStore.defaultMarkerURL(),
        fileManager: FileManager = .default
    ) {
        self.markerURL = markerURL
        self.fileManager = fileManager
    }

    public static func defaultMarkerURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/setup-state.json")
    }

    public func load() -> SetupCompletionMarker? {
        guard fileManager.fileExists(atPath: markerURL.path),
              let data = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? JSONDecoder().decode(SetupCompletionMarker.self, from: data)
    }

    public func save(_ marker: SetupCompletionMarker) throws {
        try ensureParentDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: markerURL, options: .atomic)
    }

    public func markInProgress(diskImagePath: URL) throws {
        try save(
            SetupCompletionMarker(
                status: .inProgress,
                diskImagePath: diskImagePath
            )
        )
    }

    public func markCompleted(diskImagePath: URL) throws {
        try save(
            SetupCompletionMarker(
                status: .completed,
                diskImagePath: diskImagePath
            )
        )
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try fileManager.removeItem(at: markerURL)
    }

    private func ensureParentDirectoryExists() throws {
        let parent = markerURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw WinRunError.configWriteFailed(
                    path: markerURL.path,
                    underlying: nil
                )
            }
            return
        }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }
}
