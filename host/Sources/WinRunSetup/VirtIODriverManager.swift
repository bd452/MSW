import Foundation
import WinRunShared

/// Manages VirtIO driver ISO for Windows VM provisioning.
///
/// VirtIO drivers are required for:
/// - Graphics display during Windows installation (viogpudo)
/// - Optimal storage performance (viostor)
/// - Network connectivity (NetKVM)
public actor VirtIODriverManager {
    /// URL to download VirtIO drivers from Fedora.
    public static let downloadURL = URL(
        string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    )!

    /// Expected filename for the cached ISO.
    private static let isoFilename = "virtio-win.iso"

    private let resourcesDirectory: URL?
    private let cacheDirectory: URL

    public init(resourcesDirectory: URL? = nil) {
        self.resourcesDirectory = resourcesDirectory
        self.cacheDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WinRun")
    }

    /// Returns the path to VirtIO drivers ISO, downloading if necessary.
    ///
    /// Search order:
    /// 1. Bundled in app resources
    /// 2. Cached in Application Support
    /// 3. Download from Fedora
    ///
    /// - Parameter progressHandler: Called with download progress (0.0 to 1.0).
    /// - Returns: Path to the ISO, or nil if unavailable.
    public func getDriversPath(
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        // Check bundled resources first
        if let bundled = bundledPath() {
            progressHandler?(1.0, "Using bundled VirtIO drivers")
            return bundled
        }

        // Check cache
        if let cached = cachedPath() {
            progressHandler?(1.0, "Using cached VirtIO drivers")
            return cached
        }

        // Download
        return try await downloadDrivers(progressHandler: progressHandler)
    }

    /// Returns bundled VirtIO ISO path if available.
    public func bundledPath() -> URL? {
        guard let resources = resourcesDirectory else { return nil }
        let path = resources.appendingPathComponent(Self.isoFilename)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Returns cached VirtIO ISO path if available.
    public func cachedPath() -> URL? {
        let path = cacheDirectory.appendingPathComponent(Self.isoFilename)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Downloads VirtIO drivers from Fedora.
    private func downloadDrivers(
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        progressHandler?(0.0, "Downloading VirtIO drivers (~500MB)...")

        // Ensure cache directory exists
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        let destinationPath = cacheDirectory.appendingPathComponent(Self.isoFilename)
        let tempPath = cacheDirectory.appendingPathComponent("\(Self.isoFilename).download")

        // Remove any partial download
        try? FileManager.default.removeItem(at: tempPath)

        // Download with progress tracking
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: Self.downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WinRunError.internalError(
                message: "Failed to download VirtIO drivers from \(Self.downloadURL.absoluteString)"
            )
        }

        let expectedLength = response.expectedContentLength
        var receivedLength: Int64 = 0

        // Create output file
        FileManager.default.createFile(atPath: tempPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempPath)
        defer { try? fileHandle.close() }

        // Buffer for efficient writing
        var buffer = Data()
        let bufferSize = 1024 * 1024  // 1MB buffer

        for try await byte in asyncBytes {
            buffer.append(byte)
            receivedLength += 1

            // Write buffer when full
            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)

                // Report progress
                if expectedLength > 0 {
                    let progress = Double(receivedLength) / Double(expectedLength)
                    let mbDownloaded = Double(receivedLength) / (1024 * 1024)
                    let mbTotal = Double(expectedLength) / (1024 * 1024)
                    progressHandler?(
                        progress,
                        String(format: "Downloading VirtIO drivers: %.0f/%.0f MB", mbDownloaded, mbTotal)
                    )
                }
            }
        }

        // Write remaining buffer
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }

        // Move to final location
        try? FileManager.default.removeItem(at: destinationPath)
        try FileManager.default.moveItem(at: tempPath, to: destinationPath)

        progressHandler?(1.0, "VirtIO drivers downloaded")
        return destinationPath
    }

    /// Clears cached VirtIO drivers.
    public func clearCache() throws {
        let path = cacheDirectory.appendingPathComponent(Self.isoFilename)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}
