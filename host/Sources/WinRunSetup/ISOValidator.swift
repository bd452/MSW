import Foundation
import WinRunShared

// MARK: - ISO Validator

/// Validates Windows ISO files for compatibility with WinRun.
///
/// The validator mounts the ISO, reads Windows installation metadata from
/// `sources/install.wim` or `sources/install.esd`, and determines the
/// Windows edition and architecture.
public actor ISOValidator {
    private struct MountedISO {
        let mountPoint: URL
        let shouldDetachOnCleanup: Bool
    }

    /// Logger for diagnostic output.
    private let logger: Logger?

    /// Creates a new ISO validator
    /// - Parameter logger: Optional logger for diagnostic output
    public init(logger: Logger? = nil) {
        self.logger = logger
    }

    /// Validates a Windows ISO file.
    /// - Parameter isoURL: Path to the ISO file
    /// - Returns: Validation result with edition info and warnings
    /// - Throws: `WinRunError` if the ISO cannot be validated
    public func validate(isoURL: URL) async throws -> ISOValidationResult {
        logger?.info("Validating ISO: \(isoURL.path)")

        // Verify file exists
        guard FileManager.default.fileExists(atPath: isoURL.path) else {
            throw WinRunError.isoInvalid(reason: "File not found: \(isoURL.path)")
        }

        // Verify it's a file (not directory)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: isoURL.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            throw WinRunError.isoInvalid(reason: "Path is a directory, not an ISO file")
        }

        // Mount the ISO and ensure cleanup on all exit paths
        let mountedISO = try await mountISO(at: isoURL)

        do {
            // Find and parse Windows installation metadata
            let (editionInfo, parseWarnings) = try await parseWindowsMetadata(mountPoint: mountedISO.mountPoint)

            // Generate validation warnings based on edition info
            var warnings = parseWarnings
            if let info = editionInfo {
                warnings.append(contentsOf: generateWarnings(for: info))
            }

            logger?.info(
                "ISO validation complete",
                metadata: [
                    "edition": .string(editionInfo?.editionName ?? "unknown"),
                    "architecture": .string(editionInfo?.architecture ?? "unknown"),
                    "warnings": .int(warnings.count),
                ]
            )

            // Unmount before returning
            await unmountISO(mountedISO)

            return ISOValidationResult(
                isoPath: isoURL,
                editionInfo: editionInfo,
                warnings: warnings
            )
        } catch {
            // Always unmount on error before rethrowing
            await unmountISO(mountedISO)
            throw error
        }
    }

    // MARK: - ISO Mounting

    /// Mounts an ISO file and returns the mount point
    private func mountISO(at isoURL: URL) async throws -> MountedISO {
        logger?.debug("Mounting ISO: \(isoURL.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", "-plist", isoURL.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WinRunError.isoMountFailed(
                path: isoURL.path,
                reason: "Failed to execute hdiutil: \(error.localizedDescription)"
            )
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            // If the image is already attached, re-use the existing mount point.
            if errorString.localizedCaseInsensitiveContains("Resource busy"),
               let existingMount = findExistingMountPoint(for: isoURL) {
                logger?.debug("Reusing existing ISO mount: \(existingMount.path)")
                return MountedISO(mountPoint: existingMount, shouldDetachOnCleanup: false)
            }

            throw WinRunError.isoMountFailed(
                path: isoURL.path,
                reason: errorString.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Parse plist output to find mount point
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: outputData,
                options: [],
                format: nil
            ) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw WinRunError.isoMountFailed(
                path: isoURL.path,
                reason: "Could not parse hdiutil output"
            )
        }

        // Find the mount point from the entities
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                logger?.debug("ISO mounted at: \(mountPoint)")
                return MountedISO(
                    mountPoint: URL(fileURLWithPath: mountPoint),
                    shouldDetachOnCleanup: true
                )
            }
        }

        throw WinRunError.isoMountFailed(
            path: isoURL.path,
            reason: "No mount point found in hdiutil output"
        )
    }

    /// Unmounts an ISO from the given mount point
    private func unmountISO(_ mountedISO: MountedISO) async {
        guard mountedISO.shouldDetachOnCleanup else {
            return
        }

        let mountPoint = mountedISO.mountPoint
        logger?.debug("Unmounting ISO from: \(mountPoint.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger?.warn("Failed to unmount ISO: \(error.localizedDescription)")
        }
    }

    /// Attempts to find an existing mount point for an ISO that is already attached.
    private func findExistingMountPoint(for isoURL: URL) -> URL? {
        let infoProcess = Process()
        infoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        infoProcess.arguments = ["info", "-plist"]

        let outputPipe = Pipe()
        infoProcess.standardOutput = outputPipe
        infoProcess.standardError = FileHandle.nullDevice

        do {
            try infoProcess.run()
            infoProcess.waitUntilExit()
        } catch {
            return nil
        }

        guard infoProcess.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: outputData,
                options: [],
                format: nil
            ) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else {
            return nil
        }

        let standardizedISOPath = isoURL.standardizedFileURL.path
        for image in images {
            guard let imagePath = image["image-path"] as? String else {
                continue
            }

            if URL(fileURLWithPath: imagePath).standardizedFileURL.path != standardizedISOPath {
                continue
            }

            guard let entities = image["system-entities"] as? [[String: Any]] else {
                continue
            }

            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return URL(fileURLWithPath: mountPoint)
                }
            }
        }

        return nil
    }

    // MARK: - Metadata Parsing

    /// Parses Windows metadata from a mounted ISO
    private func parseWindowsMetadata(
        mountPoint: URL
    ) async throws -> (WindowsEditionInfo?, [ISOValidationWarning]) {
        let sourcesDir = mountPoint.appendingPathComponent("sources")

        // Check for install.wim, install.esd, or split install.swm images.
        let wimPath = sourcesDir.appendingPathComponent("install.wim")
        let esdPath = sourcesDir.appendingPathComponent("install.esd")
        let splitWimPath = firstSplitInstallImage(in: sourcesDir)

        let installImagePath: URL
        if FileManager.default.fileExists(atPath: wimPath.path) {
            installImagePath = wimPath
        } else if FileManager.default.fileExists(atPath: esdPath.path) {
            installImagePath = esdPath
        } else if let splitWimPath {
            installImagePath = splitWimPath
        } else {
            // Not a valid Windows installation ISO
            throw WinRunError.isoInvalid(
                reason:
                    "No install.wim, install.esd, or install.swm found. This may not be a Windows installation ISO."
            )
        }

        logger?.debug("Found Windows image: \(installImagePath.lastPathComponent)")

        // Try to parse the WIM metadata using wiminfo (if available) or header parsing
        return try await parseWIMMetadata(at: installImagePath)
    }
}
