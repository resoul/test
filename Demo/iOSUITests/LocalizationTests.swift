import XCTest

/// Texts in the language the system gives the app (`LOCALIZATION_PROBE`; see `LocalizationProbe`):
/// the launch arguments set the app's language, the tree's locale follows, and a counted text
/// takes the plural form of the language.
final class LocalizationTests: XCTestCase {
    @MainActor
    func testTheTextsFollowTheLanguageTheAppIsLaunchedIn() {
        continueAfterFailure = false

        let english = XCUIApplication()
        english.launchEnvironment["LOCALIZATION_PROBE"] = "1"
        english.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        english.launch()
        XCTAssertTrue(english.staticTexts["Inbox"].waitForExistence(timeout: 60))
        XCTAssertTrue(english.staticTexts["1 unread message"].exists)
        english.buttons["Count 21"].tap()
        XCTAssertTrue(english.staticTexts["21 unread messages"].waitForExistence(timeout: 10))
        XCTAssertTrue(english.staticTexts["locale: en_US"].exists)
        english.terminate()

        let russian = XCUIApplication()
        russian.launchEnvironment["LOCALIZATION_PROBE"] = "1"
        russian.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        russian.launch()
        XCTAssertTrue(
            russian.staticTexts["Входящие"].waitForExistence(timeout: 60),
            "texts: \(russian.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(russian.staticTexts["locale: ru_RU"].exists)
        // One of the four Russian forms for each of the counts the buttons set.
        let forms = [
            ("Count 1", "1 непрочитанное письмо"),
            ("Count 3", "3 непрочитанных письма"),
            ("Count 5", "5 непрочитанных писем"),
            ("Count 21", "21 непрочитанное письмо"),
        ]
        for (button, text) in forms {
            russian.buttons[button].tap()
            XCTAssertTrue(
                russian.staticTexts[text].waitForExistence(timeout: 10),
                "\(button): \(russian.staticTexts.allElementsBoundByIndex.map(\.label))"
            )
        }
    }
}
