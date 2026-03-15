import Foundation
import XCTest
@testable import WinRunShared

final class QEMUToolResolverTests: XCTestCase {
    func testEnsureEFIVariableStoreCopiesTemplateOnce() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QEMUToolResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let disk = tempDir.appendingPathComponent("windows.img")
        FileManager.default.createFile(atPath: disk.path, contents: Data([0x01]), attributes: nil)

        let template = tempDir.appendingPathComponent("edk2-arm-vars.fd")
        let templateData = Data([0xAA, 0xBB, 0xCC])
        try templateData.write(to: template)

        let first = try QEMUToolResolver.ensureEFIVariableStore(
            diskImagePath: disk,
            varsTemplate: template
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: first), templateData)

        // Existing store should be reused even if template changes.
        try Data([0x00]).write(to: template)
        let second = try QEMUToolResolver.ensureEFIVariableStore(
            diskImagePath: disk,
            varsTemplate: template
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second), templateData)
    }

    func testFindQEMUUsesBinaryOverrideAfterBundleLookup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QEMUToolResolverOverride-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeQemu = tempDir.appendingPathComponent("qemu-system-aarch64")
        try "#!/bin/sh\nexit 0\n".write(to: fakeQemu, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeQemu.path)

        let resolved = QEMUToolResolver.findQEMU(environment: [
            "WINRUN_QEMU_BINARY": fakeQemu.path,
        ])
        XCTAssertEqual(resolved?.path, fakeQemu.path)
    }
}
