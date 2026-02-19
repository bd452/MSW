import Foundation

/// Canonical file paths for persisted VM identity artifacts.
///
/// These files define firmware and machine identity across installation and normal runtime.
/// Reusing the same paths keeps EFI boot state and VM identity stable across boots.
public enum VMArtifactPaths {
    /// Persisted EFI variable store.
    public static func nvramPath(for diskImagePath: URL) -> URL {
        diskImagePath
            .deletingLastPathComponent()
            .appendingPathComponent("nvram.bin")
    }

    /// Persisted machine identifier used by VZGenericPlatformConfiguration.
    public static func machineIdentifierPath(for diskImagePath: URL) -> URL {
        diskImagePath
            .deletingLastPathComponent()
            .appendingPathComponent("machine-identifier.bin")
    }
}
