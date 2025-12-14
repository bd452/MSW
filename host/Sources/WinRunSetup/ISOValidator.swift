import Foundation
import WinRunShared

// MARK: - ISO Validator

/// Validates Windows ISO files for compatibility with WinRun.
///
/// The validator mounts the ISO, reads Windows installation metadata from
/// `sources/install.wim` or `sources/install.esd`, and determines the
/// Windows edition and architecture.
public actor ISOValidator {
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
        let mountPoint = try await mountISO(at: isoURL)

        do {
            // Find and parse Windows installation metadata
            let (editionInfo, parseWarnings) = try await parseWindowsMetadata(mountPoint: mountPoint)

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
            await unmountISO(mountPoint: mountPoint)

            return ISOValidationResult(
                isoPath: isoURL,
                editionInfo: editionInfo,
                warnings: warnings
            )
        } catch {
            // Always unmount on error before rethrowing
            await unmountISO(mountPoint: mountPoint)
            throw error
        }
    }

    // MARK: - ISO Mounting

    /// Mounts an ISO file and returns the mount point
    private func mountISO(at isoURL: URL) async throws -> URL {
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
                return URL(fileURLWithPath: mountPoint)
            }
        }

        throw WinRunError.isoMountFailed(
            path: isoURL.path,
            reason: "No mount point found in hdiutil output"
        )
    }

    /// Unmounts an ISO from the given mount point
    private func unmountISO(mountPoint: URL) async {
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

    // MARK: - Metadata Parsing

    /// Parses Windows metadata from a mounted ISO
    private func parseWindowsMetadata(
        mountPoint: URL
    ) async throws -> (WindowsEditionInfo?, [ISOValidationWarning]) {
        let sourcesDir = mountPoint.appendingPathComponent("sources")

        // Check for install.wim or install.esd
        let wimPath = sourcesDir.appendingPathComponent("install.wim")
        let esdPath = sourcesDir.appendingPathComponent("install.esd")

        let installImagePath: URL
        if FileManager.default.fileExists(atPath: wimPath.path) {
            installImagePath = wimPath
        } else if FileManager.default.fileExists(atPath: esdPath.path) {
            installImagePath = esdPath
        } else {
            // Not a valid Windows installation ISO
            throw WinRunError.isoInvalid(
                reason:
                    "No install.wim or install.esd found. This may not be a Windows installation ISO."
            )
        }

        logger?.debug("Found Windows image: \(installImagePath.lastPathComponent)")

        // Try to parse the WIM metadata using wiminfo (if available) or header parsing
        return try await parseWIMMetadata(at: installImagePath)
    }

    /// Parses metadata from a WIM/ESD file
    private func parseWIMMetadata(
        at wimPath: URL
    ) async throws -> (WindowsEditionInfo?, [ISOValidationWarning]) {
        var warnings: [ISOValidationWarning] = []

        // Try wiminfo from wimlib first (more reliable)
        if let info = try await parseWithWiminfo(at: wimPath) {
            return (info, warnings)
        }

        // Fall back to parsing the WIM XML header directly
        if let info = try await parseWIMHeader(at: wimPath) {
            return (info, warnings)
        }

        // If we couldn't parse metadata, add a warning but don't fail
        warnings.append(
            ISOValidationWarning(
                severity: .warning,
                message: "Could not read detailed Windows version information",
                suggestion: "Install wimlib (brew install wimlib) for better ISO validation"
            ))

        // Try to infer architecture from boot.wim if available
        let bootWimPath = wimPath.deletingLastPathComponent().appendingPathComponent("boot.wim")
        if let arch = try await inferArchitectureFromBootWim(at: bootWimPath) {
            let info = WindowsEditionInfo(
                editionName: "Windows (unknown edition)",
                version: "0.0.0.0",
                architecture: arch
            )
            return (info, warnings)
        }

        return (nil, warnings)
    }

    /// Parses WIM metadata using wiminfo command-line tool
    private func parseWithWiminfo(at wimPath: URL) async throws -> WindowsEditionInfo? {
        // Check if wiminfo is available
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["wiminfo"]
        let whichPipe = Pipe()
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
        } catch {
            return nil
        }

        guard whichProcess.terminationStatus == 0 else {
            return nil
        }

        let wiminfoBinaryData = whichPipe.fileHandleForReading.readDataToEndOfFile()
        let wiminfoBinary =
            String(data: wiminfoBinaryData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "wiminfo"

        // Run wiminfo to get metadata
        let process = Process()
        process.executableURL = URL(fileURLWithPath: wiminfoBinary)
        process.arguments = [wimPath.path, "1"]  // Index 1 is typically the main image

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else {
            return nil
        }

        return parseWiminfoOutput(output)
    }

    /// Parses the output of wiminfo command
    private func parseWiminfoOutput(_ output: String) -> WindowsEditionInfo? {
        var editionName: String?
        var version: String?
        var architecture: String?

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Description:") {
                editionName = String(trimmed.dropFirst("Description:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Display Name:") {
                // Prefer Display Name over Description if available
                editionName = String(trimmed.dropFirst("Display Name:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Build:") {
                let buildStr = String(trimmed.dropFirst("Build:".count))
                    .trimmingCharacters(in: .whitespaces)
                version = "10.0.\(buildStr).0"
            } else if trimmed.hasPrefix("Architecture:") {
                architecture = String(trimmed.dropFirst("Architecture:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        guard let name = editionName,
            let ver = version,
            let arch = architecture
        else {
            return nil
        }

        return WindowsEditionInfo(
            editionName: name,
            version: ver,
            architecture: arch
        )
    }

    /// Parses the WIM file header directly to extract XML metadata
    private func parseWIMHeader(at wimPath: URL) async throws -> WindowsEditionInfo? {
        guard let fileHandle = FileHandle(forReadingAtPath: wimPath.path) else {
            return nil
        }
        defer { try? fileHandle.close() }

        // WIM header structure:
        // - Magic: 8 bytes "MSWIM\0\0\0"
        // - Header size: 4 bytes
        // - Flags: 4 bytes
        // - Compression size: 4 bytes
        // - WIM GUID: 16 bytes
        // - Part number: 2 bytes
        // - Total parts: 2 bytes
        // - Image count: 4 bytes
        // - Offset table offset/size: 16 bytes
        // - XML data offset: 8 bytes
        // - XML data size: 8 bytes

        // Read magic
        guard let magicData = try? fileHandle.read(upToCount: 8),
            let magic = String(data: magicData, encoding: .utf8),
            magic.hasPrefix("MSWIM")
        else {
            return nil
        }

        // Seek to XML offset location (offset 0x48 = 72 bytes)
        try? fileHandle.seek(toOffset: 0x48)
        guard let xmlOffsetData = try? fileHandle.read(upToCount: 8),
            let xmlSizeData = try? fileHandle.read(upToCount: 8)
        else {
            return nil
        }

        let xmlOffset = xmlOffsetData.withUnsafeBytes { $0.load(as: UInt64.self) }
        let xmlSize = xmlSizeData.withUnsafeBytes { $0.load(as: UInt64.self) }

        // Sanity check
        guard xmlSize > 0, xmlSize < 10_000_000 else {
            return nil
        }

        // Seek to XML data
        try? fileHandle.seek(toOffset: xmlOffset)
        guard let xmlData = try? fileHandle.read(upToCount: Int(xmlSize)) else {
            return nil
        }

        // Parse the XML
        return parseWIMXML(xmlData)
    }

    /// Parses the WIM XML metadata
    private func parseWIMXML(_ data: Data) -> WindowsEditionInfo? {
        guard let xmlString = decodeWIMXMLString(from: data) else { return nil }

        let editionName =
            extractXMLValue(from: xmlString, tag: "DISPLAYNAME")
            ?? extractXMLValue(from: xmlString, tag: "NAME")
        let architecture = extractArchitecture(from: xmlString)
        let version = extractVersion(from: xmlString)

        guard let name = editionName, let arch = architecture, let ver = version else {
            return nil
        }
        return WindowsEditionInfo(editionName: name, version: ver, architecture: arch)
    }

    /// Decodes WIM XML data (UTF-16 or UTF-8)
    private func decodeWIMXMLString(from data: Data) -> String? {
        String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
            ?? String(data: data, encoding: .utf8)
    }

    /// Extracts a simple XML tag value
    private func extractXMLValue(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)>([^<]+)</\(tag)>"
        guard let match = xml.range(of: pattern, options: .regularExpression) else { return nil }
        return xml[match]
            .replacingOccurrences(of: "<\(tag)>", with: "")
            .replacingOccurrences(of: "</\(tag)>", with: "")
    }

    /// Extracts architecture from WIM XML (ARCH: 0=x86, 9=x64, 12=ARM64)
    private func extractArchitecture(from xml: String) -> String? {
        guard
            let archValue = extractXMLValue(from: xml, tag: "ARCH")?
                .trimmingCharacters(in: .whitespaces)
        else { return nil }
        switch archValue {
        case "0": return "x86"
        case "9": return "x64"
        case "12": return "ARM64"
        default: return archValue
        }
    }

    /// Extracts version from WIM XML BUILD tag
    private func extractVersion(from xml: String) -> String? {
        guard
            let build = extractXMLValue(from: xml, tag: "BUILD")?
                .trimmingCharacters(in: .whitespaces)
        else { return nil }
        return "10.0.\(build).0"
    }

    /// Attempts to infer architecture from boot.wim
    private func inferArchitectureFromBootWim(at bootWimPath: URL) async throws -> String? {
        guard FileManager.default.fileExists(atPath: bootWimPath.path) else {
            return nil
        }

        return try await parseWIMHeader(at: bootWimPath)?.architecture
    }

    // MARK: - Warning Generation

    /// Generates warnings based on the detected Windows edition.
    /// - Parameter info: The Windows edition info to generate warnings for
    /// - Returns: Array of validation warnings
    ///
    /// This method is internal for testing purposes.
    func generateWarnings(for info: WindowsEditionInfo) -> [ISOValidationWarning] {
        var warnings: [ISOValidationWarning] = []

        // Check architecture
        if !info.isARM64 {
            warnings.append(
                ISOValidationWarning(
                    severity: .critical,
                    message:
                        "This ISO is for \(info.architecture) processors and cannot run on Apple Silicon.",
                    suggestion: "Download the ARM64 version of Windows from Microsoft."
                ))
        }

        // Check for Server edition
        if info.isServer {
            warnings.append(
                ISOValidationWarning(
                    severity: .critical,
                    message: "Windows Server does not include x86/x64 app compatibility.",
                    suggestion:
                        "Most Windows applications won't run. Consider Windows 11 IoT Enterprise LTSC instead."
                ))
        }

        // Check for Windows 10 ARM
        if !info.isWindows11 && info.isARM64 {
            warnings.append(
                ISOValidationWarning(
                    severity: .warning,
                    message: "Windows 10 ARM only supports 32-bit (x86) app emulation.",
                    suggestion:
                        "64-bit Windows apps won't work. Consider Windows 11 for full compatibility."
                ))
        }

        // Check for consumer editions
        if info.isConsumer {
            warnings.append(
                ISOValidationWarning(
                    severity: .info,
                    message:
                        "This Windows version includes consumer apps that may increase disk usage.",
                    suggestion: "For best results, use Windows 11 IoT Enterprise LTSC."
                ))
        }

        // Positive note for recommended edition
        if info.isRecommended {
            // No warnings for recommended edition
        } else if info.isWindows11 && !info.isServer && info.isARM64 && !info.isLTSC {
            warnings.append(
                ISOValidationWarning(
                    severity: .info,
                    message:
                        "Non-LTSC editions receive feature updates that may require more maintenance.",
                    suggestion:
                        "Windows 11 IoT Enterprise LTSC 2024 receives only security updates for 10 years."
                ))
        }

        return warnings
    }
}
