import Foundation
import XCTest

@testable import WinRunApp

final class ProvisioningResourceLocatorTests: XCTestCase {
    func testResolveAutounattendPath_prefersRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let rootAutounattend = root.appendingPathComponent("autounattend.xml")
        try Data("root".utf8).write(to: rootAutounattend)

        let provisionDir = root.appendingPathComponent("provision", isDirectory: true)
        try FileManager.default.createDirectory(at: provisionDir, withIntermediateDirectories: true)
        let nestedAutounattend = provisionDir.appendingPathComponent("autounattend.xml")
        try Data("nested".utf8).write(to: nestedAutounattend)

        let resolved = ProvisioningResourceLocator.resolveAutounattendPath(resourcesDirectory: root)
        XCTAssertEqual(resolved, rootAutounattend)
    }

    func testResolveAutounattendPath_fallsBackToProvisionDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let provisionDir = root.appendingPathComponent("provision", isDirectory: true)
        try FileManager.default.createDirectory(at: provisionDir, withIntermediateDirectories: true)
        let nestedAutounattend = provisionDir.appendingPathComponent("autounattend.xml")
        try Data("<xml/>".utf8).write(to: nestedAutounattend)

        let resolved = ProvisioningResourceLocator.resolveAutounattendPath(resourcesDirectory: root)
        XCTAssertEqual(resolved, nestedAutounattend)
    }

    func testResolveResourcesDirectory_usesEnvironmentRepoRoot() throws {
        let repoRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let windowsDir = repoRoot
            .appendingPathComponent("infrastructure", isDirectory: true)
            .appendingPathComponent("windows", isDirectory: true)
        try FileManager.default.createDirectory(at: windowsDir, withIntermediateDirectories: true)
        let autounattend = windowsDir.appendingPathComponent("autounattend.xml")
        try Data("<xml/>".utf8).write(to: autounattend)

        let resolved = ProvisioningResourceLocator.resolveResourcesDirectory(
            environment: ["WINRUN_REPO_ROOT": repoRoot.path]
        )
        XCTAssertEqual(resolved, windowsDir)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvisioningResourceLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
