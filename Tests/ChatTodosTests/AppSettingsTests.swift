import XCTest
@testable import ChatTodos

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "chat-todos-settings-tests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaults() {
        XCTAssertEqual(AppSettings(defaults: defaults).typography, Typography())
    }

    func testChangesPersist() {
        let settings = AppSettings(defaults: defaults)
        settings.typography.family = Typography.serif
        settings.typography.size = 16
        settings.typography.codeFamily = "Menlo"
        XCTAssertEqual(AppSettings(defaults: defaults).typography,
                       Typography(family: Typography.serif, size: 16, codeFamily: "Menlo"))
    }

    func testUninstalledFontFallsBackToSystem() {
        defaults.set("Definitely Not Installed Sans", forKey: "fontFamily")
        defaults.set("Nope Mono", forKey: "codeFontFamily")
        let typography = AppSettings(defaults: defaults).typography
        XCTAssertEqual(typography.family, Typography.system)
        XCTAssertEqual(typography.codeFamily, Typography.system)
    }

    func testSizeIsClamped() {
        defaults.set(99.0, forKey: "fontSize")
        XCTAssertEqual(AppSettings(defaults: defaults).typography.size, AppSettings.sizeRange.upperBound)
    }

    func testResetRestoresDefaults() {
        let settings = AppSettings(defaults: defaults)
        settings.typography.size = 18
        settings.reset()
        XCTAssertEqual(settings.typography, Typography())
    }

    func testMenloIsDetectedAsMonospaced() {
        XCTAssertTrue(AppSettings.monospacedFamilies.contains("Menlo"))
        XCTAssertFalse(AppSettings.monospacedFamilies.contains("Helvetica"))
    }
}
