import Foundation
import WinRunShared

/// Creates FAT12-formatted floppy disk images for Windows unattended installation.
/// Windows Setup looks for autounattend.xml on removable media including floppy drives.
public final class FloppyImageCreator: Sendable {
    /// Standard 1.44MB floppy geometry
    public static let floppySize: UInt64 = 1_474_560
    private static let bytesPerSector: UInt16 = 512
    private static let sectorsPerCluster: UInt8 = 1
    private static let reservedSectors: UInt16 = 1
    private static let numberOfFATs: UInt8 = 2
    private static let rootEntryCount: UInt16 = 224
    private static let sectorsPerFAT: UInt16 = 9
    private static let sectorsPerTrack: UInt16 = 18
    private static let numberOfHeads: UInt16 = 2
    private static let totalSectors: UInt16 = 2880

    public init() {}

    // MARK: - Public API

    /// Creates a FAT12 floppy image containing the specified files.
    /// - Parameters:
    ///   - files: Dictionary mapping destination filenames to source file URLs
    ///   - outputPath: Path where the floppy image will be created
    /// - Returns: URL of the created floppy image
    public func createFloppyImage(
        files: [String: URL],
        at outputPath: URL
    ) throws -> URL {
        // Validate input files exist
        for (name, url) in files {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WinRunError.configInvalid(reason: "File not found: \(url.path) (for \(name))")
            }
        }

        // Create the raw floppy image
        var imageData = Data(repeating: 0, count: Int(Self.floppySize))

        // Write FAT12 boot sector
        writeBootSector(to: &imageData)

        // Write FAT tables
        let fatOffset = Int(Self.reservedSectors) * Int(Self.bytesPerSector)
        writeFATTable(to: &imageData, at: fatOffset)
        let fat2Offset = fatOffset + Int(Self.sectorsPerFAT) * Int(Self.bytesPerSector)
        writeFATTable(to: &imageData, at: fat2Offset)

        // Calculate root directory offset
        let rootDirOffset = fat2Offset + Int(Self.sectorsPerFAT) * Int(Self.bytesPerSector)
        let rootDirSize = Int(Self.rootEntryCount) * 32

        // Calculate data area offset
        let dataAreaOffset = rootDirOffset + rootDirSize

        // Write files to the image
        var nextCluster: UInt16 = 2  // First usable cluster
        var rootEntryIndex = 0
        var clusterChains: [(start: UInt16, count: Int)] = []

        for (filename, sourceURL) in files.sorted(by: { $0.key < $1.key }) {
            let fileData = try Data(contentsOf: sourceURL)

            // Calculate clusters needed
            let clusterSize = Int(Self.bytesPerSector) * Int(Self.sectorsPerCluster)
            let clustersNeeded = max(1, (fileData.count + clusterSize - 1) / clusterSize)

            // Write root directory entry
            let entryOffset = rootDirOffset + (rootEntryIndex * 32)
            writeDirectoryEntry(
                to: &imageData,
                at: entryOffset,
                filename: filename,
                startCluster: nextCluster,
                fileSize: UInt32(fileData.count)
            )
            rootEntryIndex += 1

            // Record cluster chain for FAT update
            clusterChains.append((start: nextCluster, count: clustersNeeded))

            // Write file data to clusters
            for clusterIndex in 0..<clustersNeeded {
                let clusterNumber = Int(nextCluster) + clusterIndex
                let clusterOffset = dataAreaOffset + (clusterNumber - 2) * clusterSize
                let dataStart = clusterIndex * clusterSize
                let dataEnd = min(dataStart + clusterSize, fileData.count)

                if dataStart < fileData.count {
                    let chunk = fileData.subdata(in: dataStart..<dataEnd)
                    imageData.replaceSubrange(clusterOffset..<(clusterOffset + chunk.count), with: chunk)
                }
            }

            nextCluster += UInt16(clustersNeeded)
        }

        // Update FAT tables with cluster chains
        for chain in clusterChains {
            updateFATChain(
                in: &imageData,
                fatOffset: fatOffset,
                startCluster: chain.start,
                clusterCount: chain.count
            )
            updateFATChain(
                in: &imageData,
                fatOffset: fat2Offset,
                startCluster: chain.start,
                clusterCount: chain.count
            )
        }

        // Write image to disk
        try imageData.write(to: outputPath)

        return outputPath
    }

    /// Creates a floppy image for autounattend injection during Windows setup.
    /// - Parameters:
    ///   - autounattendPath: Path to the autounattend.xml file
    ///   - provisionScripts: Optional paths to provisioning scripts to include
    ///   - outputPath: Where to create the floppy image (defaults to temp directory)
    /// - Returns: URL of the created floppy image
    public func createAutounattendFloppy(
        autounattendPath: URL,
        provisionScripts: [URL] = [],
        outputPath: URL? = nil
    ) throws -> URL {
        var files: [String: URL] = [
            "AUTOUNAT.XML": autounattendPath  // 8.3 format for FAT12 compatibility
        ]

        // Add provisioning scripts if provided
        for script in provisionScripts {
            let filename = convert83Filename(script.lastPathComponent)
            files[filename] = script
        }

        let destination = outputPath ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("autounattend-\(UUID().uuidString).img")

        return try createFloppyImage(files: files, at: destination)
    }

    // MARK: - Private Implementation

    private func writeBootSector(to data: inout Data) {
        // Jump instruction
        data[0] = 0xEB  // JMP short
        data[1] = 0x3C  // offset
        data[2] = 0x90  // NOP

        // OEM Name (8 bytes)
        let oemName = "WINRUN  ".data(using: .ascii)!
        data.replaceSubrange(3..<11, with: oemName)

        // BIOS Parameter Block
        writeUInt16(Self.bytesPerSector, to: &data, at: 11)        // Bytes per sector
        data[13] = Self.sectorsPerCluster                           // Sectors per cluster
        writeUInt16(Self.reservedSectors, to: &data, at: 14)       // Reserved sectors
        data[16] = Self.numberOfFATs                                // Number of FATs
        writeUInt16(Self.rootEntryCount, to: &data, at: 17)        // Root entry count
        writeUInt16(Self.totalSectors, to: &data, at: 19)          // Total sectors
        data[21] = 0xF0                                             // Media type (1.44MB floppy)
        writeUInt16(Self.sectorsPerFAT, to: &data, at: 22)         // Sectors per FAT
        writeUInt16(Self.sectorsPerTrack, to: &data, at: 24)       // Sectors per track
        writeUInt16(Self.numberOfHeads, to: &data, at: 26)         // Number of heads
        writeUInt32(0, to: &data, at: 28)                          // Hidden sectors
        writeUInt32(0, to: &data, at: 32)                          // Total sectors (32-bit)

        // Extended boot record
        data[36] = 0x00                                             // Drive number
        data[37] = 0x00                                             // Reserved
        data[38] = 0x29                                             // Extended boot signature
        writeUInt32(0x12345678, to: &data, at: 39)                 // Volume serial number

        // Volume label (11 bytes)
        let label = "UNATTEND   ".data(using: .ascii)!
        data.replaceSubrange(43..<54, with: label)

        // File system type (8 bytes)
        let fsType = "FAT12   ".data(using: .ascii)!
        data.replaceSubrange(54..<62, with: fsType)

        // Boot signature
        data[510] = 0x55
        data[511] = 0xAA
    }

    private func writeFATTable(to data: inout Data, at offset: Int) {
        // FAT12 table header - media type and reserved entries
        data[offset] = 0xF0      // Media type (1.44MB floppy)
        data[offset + 1] = 0xFF  // Reserved
        data[offset + 2] = 0xFF  // Reserved
    }

    private func updateFATChain(
        in data: inout Data,
        fatOffset: Int,
        startCluster: UInt16,
        clusterCount: Int
    ) {
        for index in 0..<clusterCount {
            let cluster = startCluster + UInt16(index)
            let nextValue: UInt16 = (index == clusterCount - 1) ? 0xFFF : cluster + 1
            writeFAT12Entry(to: &data, fatOffset: fatOffset, cluster: cluster, value: nextValue)
        }
    }

    private func writeFAT12Entry(
        to data: inout Data,
        fatOffset: Int,
        cluster: UInt16,
        value: UInt16
    ) {
        // FAT12 packs 2 entries into 3 bytes
        let entryOffset = fatOffset + (Int(cluster) * 3 / 2)
        let isOdd = (cluster % 2) == 1

        if isOdd {
            // Odd cluster: use upper 4 bits of first byte and all of second byte
            data[entryOffset] = (data[entryOffset] & 0x0F) | UInt8((value & 0x00F) << 4)
            data[entryOffset + 1] = UInt8((value >> 4) & 0xFF)
        } else {
            // Even cluster: use all of first byte and lower 4 bits of second byte
            data[entryOffset] = UInt8(value & 0xFF)
            data[entryOffset + 1] = (data[entryOffset + 1] & 0xF0) | UInt8((value >> 8) & 0x0F)
        }
    }

    private func writeDirectoryEntry(
        to data: inout Data,
        at offset: Int,
        filename: String,
        startCluster: UInt16,
        fileSize: UInt32
    ) {
        // Convert to 8.3 format
        let (name, ext) = parse83Filename(filename)

        // Write filename (8 bytes, space-padded)
        let nameBytes = name.padding(toLength: 8, withPad: " ", startingAt: 0)
            .uppercased()
            .data(using: .ascii)!
        data.replaceSubrange(offset..<(offset + 8), with: nameBytes)

        // Write extension (3 bytes, space-padded)
        let extBytes = ext.padding(toLength: 3, withPad: " ", startingAt: 0)
            .uppercased()
            .data(using: .ascii)!
        data.replaceSubrange((offset + 8)..<(offset + 11), with: extBytes)

        // Attributes (0x20 = Archive)
        data[offset + 11] = 0x20

        // Reserved / creation time / date (set to zeros)
        for index in 12..<22 {
            data[offset + index] = 0
        }

        // Last access date
        writeUInt16(0, to: &data, at: offset + 18)

        // High word of cluster (always 0 for FAT12)
        writeUInt16(0, to: &data, at: offset + 20)

        // Last write time/date (set to a fixed value)
        writeUInt16(0x0000, to: &data, at: offset + 22)  // Time
        writeUInt16(0x0021, to: &data, at: offset + 24)  // Date (1980-01-01)

        // Starting cluster
        writeUInt16(startCluster, to: &data, at: offset + 26)

        // File size
        writeUInt32(fileSize, to: &data, at: offset + 28)
    }

    private func parse83Filename(_ filename: String) -> (name: String, ext: String) {
        let components = filename.split(separator: ".", maxSplits: 1)
        let name = String(components.first ?? "")
        let ext = components.count > 1 ? String(components[1]) : ""
        return (
            String(name.prefix(8)),
            String(ext.prefix(3))
        )
    }

    private func convert83Filename(_ filename: String) -> String {
        let (name, ext) = parse83Filename(filename)
        let truncatedName = String(name.prefix(8)).uppercased()
        let truncatedExt = String(ext.prefix(3)).uppercased()
        if truncatedExt.isEmpty {
            return truncatedName
        }
        return "\(truncatedName).\(truncatedExt)"
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
