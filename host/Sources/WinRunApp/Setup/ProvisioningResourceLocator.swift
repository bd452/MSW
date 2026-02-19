import Foundation

/// Resolves provisioning resources required for unattended Windows installation.
///
/// Resolution order:
/// 1. App bundle resources (packaged app)
/// 2. Repository fallback (developer runs via `swift run`/`make run-app`)
enum ProvisioningResourceLocator {
    static func resolveResourcesDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let bundled = Bundle.main.resourceURL, hasProvisioningResources(in: bundled, fileManager: fileManager) {
            return bundled
        }

        if let repoRoot = environment["WINRUN_REPO_ROOT"] {
            let repoURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
            let fallback = repoURL.appendingPathComponent("infrastructure/windows", isDirectory: true)
            if hasProvisioningResources(in: fallback, fileManager: fileManager) {
                return fallback
            }
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("infrastructure/windows", isDirectory: true),
            cwd.appendingPathComponent("../infrastructure/windows", isDirectory: true),
        ]

        for candidate in candidates where hasProvisioningResources(in: candidate, fileManager: fileManager) {
            return candidate
        }

        return nil
    }

    static func resolveAutounattendPath(
        resourcesDirectory: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resourcesDirectory else { return nil }
        let rootPath = resourcesDirectory.appendingPathComponent("autounattend.xml")
        if fileManager.fileExists(atPath: rootPath.path) {
            return rootPath
        }

        let provisionPath = resourcesDirectory
            .appendingPathComponent("provision")
            .appendingPathComponent("autounattend.xml")
        if fileManager.fileExists(atPath: provisionPath.path) {
            return provisionPath
        }

        return nil
    }

    private static func hasProvisioningResources(in directory: URL, fileManager: FileManager) -> Bool {
        resolveAutounattendPath(resourcesDirectory: directory, fileManager: fileManager) != nil
    }
}
