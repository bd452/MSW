import XCTest
@testable import WinRunShared

final class WinRunSharedTests: XCTestCase {
    func testVMConfigurationDefaults() {
        let config = VMConfiguration()
        XCTAssertEqual(config.resources.cpuCount, 4)
        XCTAssertEqual(config.resources.memorySizeGB, 4)
        XCTAssertTrue(config.diskImagePath.path.hasSuffix("WinRun/windows.img"))
    }
}
