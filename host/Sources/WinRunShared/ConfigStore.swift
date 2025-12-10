import Foundation

// MARK: - Config Store Errors

/// Errors that can occur during configuration loading, saving, or validation
public enum ConfigStoreError: Error, CustomStringConvertible {
    case fileReadFailed(URL, underlying: Error)
    case fileWriteFailed(URL, underlying: Error)
    case decodingFailed(URL, underlying: Error)
    case encodingFailed(underlying: Error)
    case unsupportedSchemaVersion(found: Int, maximum: Int)
    case migrationFailed(from: Int, to: Int, reason: String)
    case directoryCreationFailed(URL, underlying: Error)

    public var description: String {
        switch self {
        case .fileReadFailed(let url, let underlying):
            return "Failed to read config at \(url.path): \(underlying.localizedDescription)"
        case .fileWriteFailed(let url, let underlying):
            return "Failed to write config at \(url.path): \(underlying.localizedDescription)"
        case .decodingFailed(let url, let underlying):
            return "Failed to decode config at \(url.path): \(underlying.localizedDescription)"
        case .encodingFailed(let underlying):
            return "Failed to encode config: \(underlying.localizedDescription)"
        case .unsupportedSchemaVersion(let found, let maximum):
            return "Config schema version \(found) is newer than supported version \(maximum). Please update WinRun."
        case .migrationFailed(let from, let to, let reason):
            return "Failed to migrate config from v\(from) to v\(to): \(reason)"
        case .directoryCreationFailed(let url, let underlying):
            return "Failed to create config directory at \(url.path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Versioned Configuration

/// Wrapper that adds schema versioning to VMConfiguration for forward compatibility
public struct VersionedConfiguration: Codable {
    /// Current schema version - increment when making breaking changes
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var configuration: VMConfiguration

    public init(configuration: VMConfiguration) {
        self.schemaVersion = Self.currentSchemaVersion
        self.configuration = configuration
    }

    public init(schemaVersion: Int, configuration: VMConfiguration) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
    }
}

// MARK: - Config Store

/// Thread-safe persistent configuration store with schema validation and migration
public final class ConfigStore: @unchecked Sendable {
    private let configURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    // MARK: - Initialization

    /// Creates a config store at the specified URL
    /// - Parameters:
    ///   - configURL: Location of the config file
    ///   - fileManager: FileManager instance for file operations
    public init(configURL: URL, fileManager: FileManager = .default) {
        self.configURL = configURL
        self.fileManager = fileManager
    }

    /// Creates a config store at the default location
    /// (`~/Library/Application Support/WinRun/config.json`)
    public convenience init(fileManager: FileManager = .default) {
        let defaultURL = Self.defaultConfigURL(fileManager: fileManager)
        self.init(configURL: defaultURL, fileManager: fileManager)
    }

    /// Returns the default config file URL
    public static func defaultConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/config.json")
    }

    // MARK: - Public API

    /// Loads configuration from disk, applying migrations if needed
    /// - Returns: The loaded and validated VMConfiguration
    /// - Throws: ConfigStoreError if loading or migration fails
    public func load() throws -> VMConfiguration {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: configURL.path) else {
            return VMConfiguration()
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ConfigStoreError.fileReadFailed(configURL, underlying: error)
        }

        let versioned = try decodeVersioned(data)
        let migrated = try migrateIfNeeded(versioned)

        return migrated.configuration
    }

    /// Loads configuration from disk, returning default if not found
    /// - Returns: Loaded configuration or default values
    public func loadOrDefault() -> VMConfiguration {
        (try? load()) ?? VMConfiguration()
    }

    /// Saves configuration to disk with atomic write
    /// - Parameter configuration: The configuration to save
    /// - Throws: ConfigStoreError if saving fails
    public func save(_ configuration: VMConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveWithoutLocking(configuration)
    }

    /// Internal save that doesn't acquire the lock (caller must hold lock)
    private func saveWithoutLocking(_ configuration: VMConfiguration) throws {
        let versioned = VersionedConfiguration(configuration: configuration)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(versioned)
        } catch {
            throw ConfigStoreError.encodingFailed(underlying: error)
        }

        try ensureDirectoryExists()

        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            throw ConfigStoreError.fileWriteFailed(configURL, underlying: error)
        }
    }

    /// Loads, validates, and returns the configuration
    /// - Parameter fileManager: FileManager for validation (defaults to .default)
    /// - Returns: Validated VMConfiguration
    /// - Throws: ConfigStoreError or VMConfigurationValidationError
    public func loadAndValidate(fileManager: FileManager = .default) throws -> VMConfiguration {
        let config = try load()
        try config.validate(fileManager: fileManager)
        return config
    }

    /// Checks if a config file exists at the store location
    public var exists: Bool {
        fileManager.fileExists(atPath: configURL.path)
    }

    /// Deletes the configuration file if it exists
    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: configURL.path) else { return }

        do {
            try fileManager.removeItem(at: configURL)
        } catch {
            throw ConfigStoreError.fileWriteFailed(configURL, underlying: error)
        }
    }

    /// The URL where configuration is stored
    public var url: URL { configURL }

    // MARK: - Private Helpers

    private func ensureDirectoryExists() throws {
        let directoryURL = configURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                throw ConfigStoreError.directoryCreationFailed(directoryURL, underlying: error)
            }
        }
    }

    private func decodeVersioned(_ data: Data) throws -> VersionedConfiguration {
        let decoder = JSONDecoder()

        // Try decoding as versioned first
        if let versioned = try? decoder.decode(VersionedConfiguration.self, from: data) {
            return versioned
        }

        // Fall back to bare VMConfiguration (v0 - pre-versioning)
        do {
            let config = try decoder.decode(VMConfiguration.self, from: data)
            return VersionedConfiguration(schemaVersion: 0, configuration: config)
        } catch {
            throw ConfigStoreError.decodingFailed(configURL, underlying: error)
        }
    }

    private func migrateIfNeeded(_ versioned: VersionedConfiguration) throws -> VersionedConfiguration {
        let currentVersion = VersionedConfiguration.currentSchemaVersion

        guard versioned.schemaVersion <= currentVersion else {
            throw ConfigStoreError.unsupportedSchemaVersion(
                found: versioned.schemaVersion,
                maximum: currentVersion
            )
        }

        if versioned.schemaVersion == currentVersion {
            return versioned
        }

        // Apply migrations sequentially
        var migrated = versioned
        for version in versioned.schemaVersion..<currentVersion {
            migrated = try migrate(from: version, config: migrated)
        }

        // Save migrated config (use internal method to avoid deadlock - we already hold the lock)
        try saveWithoutLocking(migrated.configuration)

        return migrated
    }

    private func migrate(from version: Int, config: VersionedConfiguration) throws -> VersionedConfiguration {
        switch version {
        case 0:
            // v0 → v1: No structural changes, just adds version wrapper
            return VersionedConfiguration(
                schemaVersion: 1,
                configuration: config.configuration
            )
        default:
            throw ConfigStoreError.migrationFailed(
                from: version,
                to: version + 1,
                reason: "No migration path defined"
            )
        }
    }
}

// MARK: - Config Store + Defaults

public extension ConfigStore {
    /// Saves default configuration if no config file exists
    /// - Returns: true if defaults were written, false if config already existed
    @discardableResult
    func initializeWithDefaultsIfNeeded() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !fileManager.fileExists(atPath: configURL.path) else {
            return false
        }

        try saveWithoutLocking(VMConfiguration())
        return true
    }
}
