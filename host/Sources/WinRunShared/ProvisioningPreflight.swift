import Foundation

public enum ProvisioningPreflightResult: Equatable {
    case needsSetup(diskImagePath: URL, reason: Reason)
    case ready(configuration: VMConfiguration)

    public enum Reason: String, Equatable {
        case diskImageMissing
        case diskImageIsDirectory
    }
}

public struct ProvisioningPreflight {
    public init() {}

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

        return .ready(configuration: configuration)
    }
}
