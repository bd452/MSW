import Foundation
import WinRunShared

/// Creates small ISO images containing autounattend.xml for unattended installation.
///
/// Since Virtualization.framework doesn't support floppy drives, we create
/// a small ISO (just a few MB) containing only autounattend.xml and provisioning
/// scripts. This ISO is mounted as a second CD-ROM device alongside the Windows
/// installation ISO. Windows Setup will automatically detect and use autounattend.xml
/// from any removable media, including a second CD-ROM.
public actor ISOModifier {
    /// Logger for diagnostic output.
    private let logger: Logger?
    /// Cache for created autounattend ISOs (autounattend path -> ISO path)
    private var isoCache: [URL: URL] = [:]

    /// Creates a new ISO modifier.
    /// - Parameter logger: Optional logger for diagnostic output
    public init(logger: Logger? = nil) {
        self.logger = logger
    }

    /// Creates a small ISO containing autounattend.xml and provisioning scripts.
    ///
    /// This creates a lightweight ISO (typically < 10MB) that can be mounted as
    /// a second CD-ROM device alongside the Windows installation ISO. Windows Setup
    /// will find autounattend.xml in the root of this ISO.
    ///
    /// Results are cached per autounattend.xml path to avoid recreating identical ISOs.
    ///
    /// - Parameters:
    ///   - autounattendPath: Path to the autounattend.xml file
    ///   - provisionScripts: Optional array of provisioning script paths to include
    ///   - outputPath: Optional path for the created ISO (defaults to temp directory)
    /// - Returns: URL of the created ISO
    /// - Throws: `WinRunError` if the ISO cannot be created
    public func createAutounattendISO(
        autounattendPath: URL,
        provisionScripts: [URL] = [],
        outputPath: URL? = nil
    ) async throws -> URL {
        // Check cache first
        if let cached = isoCache[autounattendPath] {
            logger?.debug("Using cached autounattend ISO: \(cached.path)")
            return cached
        }

        logger?.info("Creating autounattend ISO with: \(autounattendPath.path)")

        // Validate inputs
        guard FileManager.default.fileExists(atPath: autounattendPath.path) else {
            throw WinRunError.configInvalid(reason: "Autounattend.xml not found: \(autounattendPath.path)")
        }

        // Determine output path
        let autounattendISO = outputPath ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("winrun-autounattend-\(UUID().uuidString).iso")

        // Create temporary directory for ISO contents
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("winrun-autounattend-\(UUID().uuidString)")

        do {
            // Create temp directory
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )

            // Copy autounattend.xml to root of temp directory
            let autounattendDest = tempDir.appendingPathComponent("autounattend.xml")
            try FileManager.default.copyItem(at: autounattendPath, to: autounattendDest)

            logger?.debug("autounattend.xml copied to ISO root")

            // Copy provisioning scripts to root of temp directory
            for script in provisionScripts {
                guard FileManager.default.fileExists(atPath: script.path) else {
                    logger?.warn("Provisioning script not found, skipping: \(script.path)")
                    continue
                }
                let scriptDest = tempDir.appendingPathComponent(script.lastPathComponent)
                try FileManager.default.copyItem(at: script, to: scriptDest)
                logger?.debug("Provisioning script copied: \(script.lastPathComponent)")
            }

            // Create small ISO from contents
            try await createISO(from: tempDir, output: autounattendISO)

            logger?.info("Autounattend ISO created: \(autounattendISO.path)")

            // Clean up temp directory
            try? FileManager.default.removeItem(at: tempDir)

            // Cache the result
            isoCache[autounattendPath] = autounattendISO

            return autounattendISO
        } catch {
            // Clean up on error
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    // MARK: - ISO Creation

    /// Creates an ISO9660 image from a directory using hdiutil
    private func createISO(from directory: URL, output: URL) async throws {
        logger?.debug("Creating ISO from \(directory.path) to \(output.path)")

        // Ensure parent directory exists
        let parentDir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )

        // Use hdiutil makehybrid to create ISO9660 image
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid",
            "-iso",
            "-joliet",
            "-o", output.path,
            directory.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WinRunError.internalError(
                message: "Failed to create ISO: \(error.localizedDescription)"
            )
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw WinRunError.internalError(
                message: "Failed to create ISO: \(errorString)"
            )
        }

        logger?.debug("ISO created successfully")
    }
}
