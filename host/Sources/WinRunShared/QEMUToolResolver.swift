import Foundation

public struct QEMUToolPaths: Sendable {
    public let qemuBinary: URL
    public let swtpmBinary: URL
    public let firmwareCode: URL
    public let firmwareVarsTemplate: URL
}

public enum QEMUToolResolverError: LocalizedError {
    case qemuNotFound
    case swtpmNotFound
    case firmwareNotFound(String)
    case varsTemplateNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .qemuNotFound:
            return "qemu-system-aarch64 was not found in the app bundle, Homebrew, or PATH."
        case .swtpmNotFound:
            return "swtpm was not found in the app bundle, Homebrew, or PATH."
        case .firmwareNotFound(let name):
            return "Required QEMU firmware file not found: \(name)"
        case .varsTemplateNotFound(let name):
            return "Required QEMU vars template not found: \(name)"
        }
    }
}

public enum QEMUToolResolver {
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> QEMUToolPaths {
        guard let qemuBinary = findQEMU(environment: environment) else {
            throw QEMUToolResolverError.qemuNotFound
        }
        guard let swtpmBinary = findSwtpm(environment: environment) else {
            throw QEMUToolResolverError.swtpmNotFound
        }
        guard let firmwareCode = findQEMUShareFile("edk2-aarch64-code.fd", qemuBinary: qemuBinary) else {
            throw QEMUToolResolverError.firmwareNotFound("edk2-aarch64-code.fd")
        }
        guard let firmwareVarsTemplate = findQEMUShareFile("edk2-arm-vars.fd", qemuBinary: qemuBinary) else {
            throw QEMUToolResolverError.varsTemplateNotFound("edk2-arm-vars.fd")
        }
        return QEMUToolPaths(
            qemuBinary: qemuBinary,
            swtpmBinary: swtpmBinary,
            firmwareCode: firmwareCode,
            firmwareVarsTemplate: firmwareVarsTemplate
        )
    }

    public static func findQEMU(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        findExecutable(
            named: "qemu-system-aarch64",
            environment: environment,
            binaryOverrideKey: "WINRUN_QEMU_BINARY",
            prefixOverrideKey: "WINRUN_QEMU_PREFIX"
        )
    }

    public static func findSwtpm(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        findExecutable(
            named: "swtpm",
            environment: environment,
            binaryOverrideKey: "WINRUN_SWTPM_BINARY",
            prefixOverrideKey: "WINRUN_SWTPM_PREFIX"
        )
    }

    public static func findQEMUShareFile(_ filename: String, qemuBinary: URL) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let overrideShare = environment["WINRUN_QEMU_SHARE_DIR"], !overrideShare.isEmpty {
            let overridePath = URL(fileURLWithPath: overrideShare).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: overridePath.path) {
                return overridePath
            }
        }
        if let overridePrefix = environment["WINRUN_QEMU_PREFIX"], !overridePrefix.isEmpty {
            let overridePath = URL(fileURLWithPath: overridePrefix).appendingPathComponent("share/qemu/\(filename)")
            if FileManager.default.fileExists(atPath: overridePath.path) {
                return overridePath
            }
        }

        let prefix = qemuBinary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let derived = prefix.appendingPathComponent("share/qemu/\(filename)")
        if FileManager.default.fileExists(atPath: derived.path) {
            return derived
        }

        if let bundleResource = Bundle.main.resourceURL {
            let bundled = bundleResource.appendingPathComponent("qemu/share/qemu/\(filename)")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        if let brewQEMU = queryBrewPrefix(formula: "qemu") {
            let candidate = brewQEMU.appendingPathComponent("share/qemu/\(filename)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    public static func ensureEFIVariableStore(
        diskImagePath: URL,
        varsTemplate: URL
    ) throws -> URL {
        let nvramPath = diskImagePath
            .deletingPathExtension()
            .appendingPathExtension("qemu-nvram")

        if FileManager.default.fileExists(atPath: nvramPath.path) {
            return nvramPath
        }

        let parentDir = nvramPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: varsTemplate, to: nvramPath)
        return nvramPath
    }

    static func findExecutable(
        named name: String,
        environment: [String: String],
        binaryOverrideKey: String,
        prefixOverrideKey: String
    ) -> URL? {
        if let bundled = bundledExecutable(named: name) {
            return bundled
        }
        if let overrideBinary = environment[binaryOverrideKey], !overrideBinary.isEmpty {
            let overrideURL = URL(fileURLWithPath: overrideBinary)
            if FileManager.default.isExecutableFile(atPath: overrideURL.path) {
                return overrideURL
            }
        }
        if let overridePrefix = environment[prefixOverrideKey], !overridePrefix.isEmpty {
            let candidate = URL(fileURLWithPath: overridePrefix).appendingPathComponent("bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        if let brewPrefix = queryBrewPrefix() {
            let candidate = brewPrefix.appendingPathComponent("bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return whichExecutable(name)
    }

    static func bundledExecutable(named name: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("qemu/bin/\(name)"),
            resourceURL.appendingPathComponent("\(name)"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    public static func queryBrewPrefix(formula: String? = nil) -> URL? {
        guard let brew = whichExecutable("brew") else { return nil }
        var arguments = ["--prefix"]
        if let formula {
            arguments.append(formula)
        }

        let proc = Process()
        proc.executableURL = brew
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(bytes: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func whichExecutable(_ name: String) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(bytes: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
