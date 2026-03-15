import Foundation
import WinRunShared

extension ISOValidator {
    /// Parses metadata from a WIM/ESD file, trying wiminfo then direct header parsing.
    func parseWIMMetadata(
        at wimPath: URL
    ) async throws -> (WindowsEditionInfo?, [ISOValidationWarning]) {
        var warnings: [ISOValidationWarning] = []

        if let info = try await parseWithWiminfo(at: wimPath) {
            return (info, warnings)
        }

        if let info = try await parseWIMHeader(at: wimPath) {
            return (info, warnings)
        }

        warnings.append(
            ISOValidationWarning(
                severity: .warning,
                message: "Could not read detailed Windows version information",
                suggestion: "Install wimlib (brew install wimlib) for better ISO validation"
            ))

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

    /// Parses WIM metadata using wiminfo command-line tool.
    private func parseWithWiminfo(at wimPath: URL) async throws -> WindowsEditionInfo? {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wiminfoBinary)
        process.arguments = [wimPath.path, "1"]

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

    /// Parses the WIM file header directly to extract XML metadata.
    func parseWIMHeader(at wimPath: URL) async throws -> WindowsEditionInfo? {
        guard let fileHandle = FileHandle(forReadingAtPath: wimPath.path) else {
            return nil
        }
        defer { try? fileHandle.close() }

        guard let magicData = try? fileHandle.read(upToCount: 8),
            let magic = String(data: magicData, encoding: .utf8),
            magic.hasPrefix("MSWIM")
        else {
            return nil
        }

        try? fileHandle.seek(toOffset: 0x48)
        guard let xmlOffsetData = try? fileHandle.read(upToCount: 8),
            let xmlSizeData = try? fileHandle.read(upToCount: 8)
        else {
            return nil
        }

        let xmlOffset = xmlOffsetData.withUnsafeBytes { $0.load(as: UInt64.self) }
        let xmlSize = xmlSizeData.withUnsafeBytes { $0.load(as: UInt64.self) }

        guard xmlSize > 0, xmlSize < 10_000_000 else {
            return nil
        }

        try? fileHandle.seek(toOffset: xmlOffset)
        guard let xmlData = try? fileHandle.read(upToCount: Int(xmlSize)) else {
            return nil
        }

        return parseWIMXML(xmlData)
    }

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

    private func decodeWIMXMLString(from data: Data) -> String? {
        String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
            ?? String(data: data, encoding: .utf8)
    }

    private func extractXMLValue(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)>([^<]+)</\(tag)>"
        guard let match = xml.range(of: pattern, options: .regularExpression) else { return nil }
        return xml[match]
            .replacingOccurrences(of: "<\(tag)>", with: "")
            .replacingOccurrences(of: "</\(tag)>", with: "")
    }

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

    private func extractVersion(from xml: String) -> String? {
        guard
            let build = extractXMLValue(from: xml, tag: "BUILD")?
                .trimmingCharacters(in: .whitespaces)
        else { return nil }
        return "10.0.\(build).0"
    }

    private func inferArchitectureFromBootWim(at bootWimPath: URL) async throws -> String? {
        guard FileManager.default.fileExists(atPath: bootWimPath.path) else {
            return nil
        }
        return try await parseWIMHeader(at: bootWimPath)?.architecture
    }

    /// Finds the first split WIM image (install.swm) in the mounted ISO sources directory.
    func firstSplitInstallImage(in sourcesDir: URL) -> URL? {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: sourcesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        return entries
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasPrefix("install") && name.hasSuffix(".swm")
            }
            .min {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    // MARK: - Warning Generation

    func generateWarnings(for info: WindowsEditionInfo) -> [ISOValidationWarning] {
        var warnings: [ISOValidationWarning] = []

        if !info.isARM64 {
            warnings.append(
                ISOValidationWarning(
                    severity: .critical,
                    message:
                        "This ISO is for \(info.architecture) processors "
                        + "and cannot run on Apple Silicon.",
                    suggestion: "Download the ARM64 version of Windows from Microsoft."
                ))
        }

        if info.isServer {
            warnings.append(
                ISOValidationWarning(
                    severity: .critical,
                    message: "Windows Server does not include x86/x64 app compatibility.",
                    suggestion:
                        "Most Windows applications won't run. "
                        + "Consider Windows 11 IoT Enterprise LTSC instead."
                ))
        }

        if !info.isWindows11 && info.isARM64 {
            warnings.append(
                ISOValidationWarning(
                    severity: .warning,
                    message: "Windows 10 ARM only supports 32-bit (x86) app emulation.",
                    suggestion:
                        "64-bit Windows apps won't work. "
                        + "Consider Windows 11 for full compatibility."
                ))
        }

        if info.isConsumer {
            warnings.append(
                ISOValidationWarning(
                    severity: .info,
                    message:
                        "This Windows version includes consumer apps "
                        + "that may increase disk usage.",
                    suggestion: "For best results, use Windows 11 IoT Enterprise LTSC."
                ))
        }

        if !info.isRecommended && info.isWindows11 && !info.isServer
            && info.isARM64 && !info.isLTSC {
            warnings.append(
                ISOValidationWarning(
                    severity: .info,
                    message:
                        "Non-LTSC editions receive feature updates "
                        + "that may require more maintenance.",
                    suggestion:
                        "Windows 11 IoT Enterprise LTSC 2024 receives "
                        + "only security updates for 10 years."
                ))
        }

        return warnings
    }
}
