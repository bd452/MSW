import WinRunShared
import XCTest

@testable import WinRunSetup

final class ISOValidatorTests: XCTestCase {
    // MARK: - WindowsEditionInfo Tests

    func testWindowsEditionInfo_ARM64Detection() {
        let info = WindowsEditionInfo(
            editionName: "Windows 11 IoT Enterprise LTSC",
            version: "10.0.26100.1",
            architecture: "ARM64"
        )

        XCTAssertTrue(info.isARM64)
        XCTAssertEqual(info.buildNumber, 26100)
    }

    func testWindowsEditionInfo_ARM64CaseInsensitive() {
        let info = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "arm64"
        )

        XCTAssertTrue(info.isARM64)
    }

    func testWindowsEditionInfo_x64NotARM64() {
        let info = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "x64"
        )

        XCTAssertFalse(info.isARM64)
    }

    func testWindowsEditionInfo_Windows11Detection() {
        // Windows 11 starts at build 22000
        let win11 = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertTrue(win11.isWindows11)

        let win11Later = WindowsEditionInfo(
            editionName: "Windows 11 IoT Enterprise LTSC",
            version: "10.0.26100.1",
            architecture: "ARM64"
        )
        XCTAssertTrue(win11Later.isWindows11)

        let win10 = WindowsEditionInfo(
            editionName: "Windows 10 Pro",
            version: "10.0.19045.1",
            architecture: "ARM64"
        )
        XCTAssertFalse(win10.isWindows11)
    }

    func testWindowsEditionInfo_LTSCDetection() {
        let ltsc = WindowsEditionInfo(
            editionName: "Windows 11 IoT Enterprise LTSC",
            version: "10.0.26100.1",
            architecture: "ARM64"
        )
        XCTAssertTrue(ltsc.isLTSC)

        let regular = WindowsEditionInfo(
            editionName: "Windows 11 Enterprise",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertFalse(regular.isLTSC)
    }

    func testWindowsEditionInfo_IoTEnterpriseDetection() {
        let iot = WindowsEditionInfo(
            editionName: "Windows 11 IoT Enterprise LTSC",
            version: "10.0.26100.1",
            architecture: "ARM64"
        )
        XCTAssertTrue(iot.isIoTEnterprise)

        let regular = WindowsEditionInfo(
            editionName: "Windows 11 Enterprise",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertFalse(regular.isIoTEnterprise)
    }

    func testWindowsEditionInfo_ServerDetection() {
        let server = WindowsEditionInfo(
            editionName: "Windows Server 2022",
            version: "10.0.20348.1",
            architecture: "ARM64"
        )
        XCTAssertTrue(server.isServer)

        let client = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertFalse(client.isServer)
    }

    func testWindowsEditionInfo_ConsumerDetection() {
        let home = WindowsEditionInfo(
            editionName: "Windows 11 Home",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertTrue(home.isConsumer)

        let pro = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertTrue(pro.isConsumer)

        let enterprise = WindowsEditionInfo(
            editionName: "Windows 11 Enterprise",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertFalse(enterprise.isConsumer)

        let proEnterprise = WindowsEditionInfo(
            editionName: "Windows 11 Pro for Enterprise",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertFalse(proEnterprise.isConsumer)
    }

    func testWindowsEditionInfo_BuildNumberParsing() {
        let info = WindowsEditionInfo(
            editionName: "Test",
            version: "10.0.26100.1234",
            architecture: "ARM64"
        )
        XCTAssertEqual(info.buildNumber, 26100)

        let shortVersion = WindowsEditionInfo(
            editionName: "Test",
            version: "10.0",
            architecture: "ARM64"
        )
        XCTAssertNil(shortVersion.buildNumber)

        let invalidVersion = WindowsEditionInfo(
            editionName: "Test",
            version: "invalid",
            architecture: "ARM64"
        )
        XCTAssertNil(invalidVersion.buildNumber)
    }

    // MARK: - ISOValidationWarning Tests

    func testISOValidationWarning_Equality() {
        let warning1 = ISOValidationWarning(
            severity: .critical,
            message: "Test message",
            suggestion: "Test suggestion"
        )
        let warning2 = ISOValidationWarning(
            severity: .critical,
            message: "Test message",
            suggestion: "Test suggestion"
        )
        XCTAssertEqual(warning1, warning2)

        let warning3 = ISOValidationWarning(
            severity: .warning,
            message: "Test message",
            suggestion: "Test suggestion"
        )
        XCTAssertNotEqual(warning1, warning3)
    }

    // MARK: - ISOValidationResult Tests

    func testISOValidationResult_IsUsable() {
        let usable = ISOValidationResult(
            isoPath: URL(fileURLWithPath: "/test.iso"),
            editionInfo: WindowsEditionInfo(
                editionName: "Windows 11 Pro",
                version: "10.0.22000.1",
                architecture: "ARM64"
            ),
            warnings: []
        )
        XCTAssertTrue(usable.isUsable)

        let notUsable = ISOValidationResult(
            isoPath: URL(fileURLWithPath: "/test.iso"),
            editionInfo: WindowsEditionInfo(
                editionName: "Windows 11 Pro",
                version: "10.0.22000.1",
                architecture: "x64"
            ),
            warnings: []
        )
        XCTAssertFalse(notUsable.isUsable)

        let noInfo = ISOValidationResult(
            isoPath: URL(fileURLWithPath: "/test.iso"),
            editionInfo: nil,
            warnings: []
        )
        XCTAssertFalse(noInfo.isUsable)
    }

    func testISOValidationResult_IsRecommended() {
        let recommended = ISOValidationResult(
            isoPath: URL(fileURLWithPath: "/test.iso"),
            editionInfo: WindowsEditionInfo(
                editionName: "Windows 11 IoT Enterprise LTSC",
                version: "10.0.26100.1",
                architecture: "ARM64"
            ),
            warnings: []
        )
        XCTAssertTrue(recommended.isRecommended)

        let notLTSC = ISOValidationResult(
            isoPath: URL(fileURLWithPath: "/test.iso"),
            editionInfo: WindowsEditionInfo(
                editionName: "Windows 11 Pro",
                version: "10.0.22000.1",
                architecture: "ARM64"
            ),
            warnings: []
        )
        XCTAssertFalse(notLTSC.isRecommended)

        let notIoT = ISOValidationResult(
            isoPath: URL(fileURLWithPath: "/test.iso"),
            editionInfo: WindowsEditionInfo(
                editionName: "Windows 11 Enterprise LTSC",
                version: "10.0.26100.1",
                architecture: "ARM64"
            ),
            warnings: []
        )
        XCTAssertFalse(notIoT.isRecommended)
    }

    // MARK: - Warning Generation Tests with Mock Metadata

    func testGenerateWarnings_NonARM64Architecture() async {
        let validator = ISOValidator()
        let info = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "x64"
        )

        let warnings = await validator.generateWarnings(for: info)

        XCTAssertTrue(warnings.contains { $0.severity == .critical })
        XCTAssertTrue(warnings.contains { $0.message.contains("x64") })
        XCTAssertTrue(warnings.contains { $0.message.contains("Apple Silicon") })
    }

    func testGenerateWarnings_ServerEdition() async {
        let validator = ISOValidator()
        let info = WindowsEditionInfo(
            editionName: "Windows Server 2022",
            version: "10.0.20348.1",
            architecture: "ARM64"
        )

        let warnings = await validator.generateWarnings(for: info)

        XCTAssertTrue(warnings.contains { $0.severity == .critical })
        XCTAssertTrue(warnings.contains { $0.message.contains("Server") })
        XCTAssertTrue(warnings.contains { $0.message.contains("x86/x64 app compatibility") })
    }

    func testGenerateWarnings_Windows10ARM() async {
        let validator = ISOValidator()
        let info = WindowsEditionInfo(
            editionName: "Windows 10 Pro",
            version: "10.0.19045.1",
            architecture: "ARM64"
        )

        let warnings = await validator.generateWarnings(for: info)

        XCTAssertTrue(warnings.contains { $0.severity == .warning })
        XCTAssertTrue(warnings.contains { $0.message.contains("32-bit") })
        XCTAssertTrue(warnings.contains { $0.suggestion?.contains("Windows 11") ?? false })
    }

    func testGenerateWarnings_ConsumerEdition() async {
        let validator = ISOValidator()
        let info = WindowsEditionInfo(
            editionName: "Windows 11 Home",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )

        let warnings = await validator.generateWarnings(for: info)

        XCTAssertTrue(warnings.contains { $0.severity == .info })
        XCTAssertTrue(warnings.contains { $0.message.contains("consumer apps") })
    }

    func testGenerateWarnings_NonLTSCEdition() async {
        let validator = ISOValidator()
        let info = WindowsEditionInfo(
            editionName: "Windows 11 Enterprise",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )

        let warnings = await validator.generateWarnings(for: info)

        XCTAssertTrue(warnings.contains { $0.severity == .info })
        XCTAssertTrue(warnings.contains { $0.message.contains("Non-LTSC") })
        XCTAssertTrue(warnings.contains { $0.message.contains("feature updates") })
    }

    func testGenerateWarnings_RecommendedEditionNoWarnings() async {
        let validator = ISOValidator()
        let info = WindowsEditionInfo(
            editionName: "Windows 11 IoT Enterprise LTSC",
            version: "10.0.26100.1",
            architecture: "ARM64"
        )

        let warnings = await validator.generateWarnings(for: info)

        // Recommended edition should have no warnings
        XCTAssertTrue(warnings.isEmpty, "Expected no warnings for recommended edition")
    }

    func testGenerateWarnings_MultipleIssues() async {
        let validator = ISOValidator()
        // x64 + Server = two critical warnings
        let info = WindowsEditionInfo(
            editionName: "Windows Server 2022",
            version: "10.0.20348.1",
            architecture: "x64"
        )

        let warnings = await validator.generateWarnings(for: info)

        let criticalCount = warnings.filter { $0.severity == .critical }.count
        XCTAssertEqual(criticalCount, 2, "Expected two critical warnings for x64 Server edition")
    }

    func testGenerateWarnings_x86Architecture() async {
        let validator = ISOValidator()
        let info = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "x86"
        )

        let warnings = await validator.generateWarnings(for: info)

        XCTAssertTrue(warnings.contains { $0.severity == .critical })
        XCTAssertTrue(warnings.contains { $0.message.contains("x86") })
    }

    // MARK: - Error Handling Tests

    func testValidator_ThrowsForNonexistentFile() async throws {
        let validator = ISOValidator()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/path/to/fake.iso")

        do {
            _ = try await validator.validate(isoURL: fakeURL)
            XCTFail("Expected error to be thrown")
        } catch let error as WinRunError {
            switch error {
            case .isoInvalid(let reason):
                XCTAssertTrue(reason.contains("not found"))
            default:
                XCTFail("Expected isoInvalid error, got \(error)")
            }
        }
    }

    func testValidator_ThrowsForDirectory() async throws {
        let validator = ISOValidator()
        let dirURL = URL(fileURLWithPath: NSTemporaryDirectory())

        do {
            _ = try await validator.validate(isoURL: dirURL)
            XCTFail("Expected error to be thrown")
        } catch let error as WinRunError {
            switch error {
            case .isoInvalid(let reason):
                XCTAssertTrue(reason.contains("directory"))
            default:
                XCTFail("Expected isoInvalid error, got \(error)")
            }
        }
    }

    // MARK: - WindowsEditionInfo Equatable Tests

    func testWindowsEditionInfo_Equality() {
        let info1 = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        let info2 = WindowsEditionInfo(
            editionName: "Windows 11 Pro",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertEqual(info1, info2)

        let info3 = WindowsEditionInfo(
            editionName: "Windows 11 Home",
            version: "10.0.22000.1",
            architecture: "ARM64"
        )
        XCTAssertNotEqual(info1, info3)
    }
}
