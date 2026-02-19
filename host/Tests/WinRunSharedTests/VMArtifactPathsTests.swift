import Foundation
import XCTest

@testable import WinRunShared

final class VMArtifactPathsTests: XCTestCase {
    func testArtifactPathsUseDiskDirectory() {
        let diskPath = URL(fileURLWithPath: "/tmp/winrun/windows.img")

        XCTAssertEqual(
            VMArtifactPaths.nvramPath(for: diskPath).path,
            "/tmp/winrun/nvram.bin"
        )
        XCTAssertEqual(
            VMArtifactPaths.machineIdentifierPath(for: diskPath).path,
            "/tmp/winrun/machine-identifier.bin"
        )
    }
}
