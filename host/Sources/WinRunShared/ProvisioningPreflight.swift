import Foundation

public enum ProvisioningPreflightResult: Equatable {
    case needsSetup(diskImagePath: URL, reason: Reason)
    case ready(configuration: VMConfiguration)

    public enum Reason: String, Equatable {
        case diskImageMissing
        case diskImageIsDirectory
        case setupIncomplete
    }
}

public struct ProvisioningPreflight {
    public init() {}

    /// Marks setup complete for the given disk image path.
    @discardableResult
    public static func markSetupComplete(
        diskImagePath: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let markerURL = setupCompletionMarkerURL(for: diskImagePath)
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = "complete\n\(diskImagePath.path)\n".data(using: .utf8) ?? Data("complete".utf8)
            try payload.write(to: markerURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func evaluate(
        configStore: ConfigStore = ConfigStore(),
        fileManager: FileManager = .default
    ) -> ProvisioningPreflightResult {
        let configuration = configStore.loadOrDefault()
        let diskURL = configuration.diskImagePath

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: diskURL.path, isDirectory: &isDirectory) else {
            return .needsSetup(diskImagePath: diskURL, reason: .diskImageMissing)
        }

        if isDirectory.boolValue {
            return .needsSetup(diskImagePath: diskURL, reason: .diskImageIsDirectory)
        }

        let markerURL = setupCompletionMarkerURL(for: diskURL)
        guard fileManager.fileExists(atPath: markerURL.path) else {
            return .needsSetup(diskImagePath: diskURL, reason: .setupIncomplete)
        }

        return .ready(configuration: configuration)
    }

    private static func setupCompletionMarkerURL(for diskImagePath: URL) -> URL {
        let filename = diskImagePath.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        return diskImagePath
            .deletingLastPathComponent()
            .appendingPathComponent(".setup-complete-\(filename).marker")
    }
}
