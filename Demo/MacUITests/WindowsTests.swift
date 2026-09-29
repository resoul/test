import XCTest

/// Several windows and the settings window (`WINDOWS_PROBE`; see `WindowsProbe`): a new window
/// from the File menu has its own path, and every window comes back after a relaunch with its
/// own; the settings window is one, opens from the app's menu, and is not there at launch.
/// The state is kept between runs of a test, and a launch that ignores it does not keep its
/// own either, so the test that relaunches brings what the last run left to one window at the
/// start of its path, and the one that does not relaunch ignores it.
final class WindowsTests: XCTestCase {
    @MainActor
    private func launch(ignoringSavedState: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WINDOWS_PROBE"] = "1"
        app.launchEnvironment["RESTORATION_PROBE"] = "1"
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "YES"]
        if ignoringSavedState {
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        }
        app.launch()
        return app
    }

    /// The windows showing `text`.
    @MainActor
    private func windows(showing text: String, in app: XCUIApplication) -> Int {
        app.windows.containing(.staticText, identifier: text).count
    }

    /// Closes the windows the last run left but one, and takes that one back to the first note.
    @MainActor
    private func makeOneWindowAtTheStart(of app: XCUIApplication) {
        while app.windows.count > 1 {
            let count = app.windows.count
            app.windows.element(boundBy: 0).buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(app.wait(for: { $0.windows.count < count }, timeout: 10))
        }
        for _ in 0..<10 where !app.staticTexts["Note 1"].waitForExistence(timeout: 2) {
            app.windows.firstMatch.buttons["Back"].click()
        }
        XCTAssertTrue(app.staticTexts["Note 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    private func choose(_ item: String, inMenu menu: Int, of app: XCUIApplication) {
        app.menuBars.menuBarItems.element(boundBy: menu).click()
        let entry = app.menuBars.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no menu item \(item)")
        entry.click()
    }

    @MainActor
    func testANewWindowHasItsOwnPathAndEveryWindowComesBackWithItsOwn() {
        continueAfterFailure = false
        var app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        makeOneWindowAtTheStart(of: app)
        app.buttons["Next note"].click()
        XCTAssertTrue(app.staticTexts["Note 2"].waitForExistence(timeout: 5))

        // File > New Window: a second window, at the start of its own path.
        choose("New Window", inMenu: 2, of: app)
        XCTAssertTrue(app.wait(for: { $0.windows.count == 2 }, timeout: 10))
        XCTAssertEqual(windows(showing: "Note 1", in: app), 1)
        XCTAssertEqual(windows(showing: "Note 2", in: app), 1)
        // The new window is the front one: its button is the one pressed, twice, the second time
        // when the screen of the first press has come in (a push slides, and the screen going
        // out is still there while it does).
        let front = app.windows.element(boundBy: 0)
        front.buttons["Next note"].click()
        XCTAssertTrue(front.staticTexts["Note 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(front.staticTexts["Note 1"].waitForNonExistence(timeout: 5))
        front.buttons["Next note"].click()
        XCTAssertTrue(front.staticTexts["Note 3"].waitForExistence(timeout: 5))
        XCTAssertEqual(windows(showing: "Note 2", in: app), 1)
        XCTAssertEqual(windows(showing: "Note 3", in: app), 1)

        // Quit from the menu, as a user does, and open the app again.
        choose("Quit \(app.menuBars.menuBarItems.element(boundBy: 1).title)", inMenu: 1, of: app)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
        app = launch()

        XCTAssertTrue(app.staticTexts["Note 2"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.wait(for: { $0.windows.count == 2 }, timeout: 10))
        XCTAssertEqual(windows(showing: "Note 2", in: app), 1)
        XCTAssertEqual(windows(showing: "Note 3", in: app), 1)
    }

    @MainActor
    func testTheSettingsWindowIsOneOpensFromTheAppMenuAndIsNotThereAtLaunch() {
        continueAfterFailure = false
        let app = launch(ignoringSavedState: true)
        XCTAssertTrue(app.staticTexts["Note 1"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(windows(showing: "Settings screen", in: app), 0)

        choose("Settings…", inMenu: 1, of: app)
        XCTAssertTrue(app.staticTexts["Settings screen"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 2)

        // Asked again, it is the same window that comes forward.
        choose("Settings…", inMenu: 1, of: app)
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(windows(showing: "Settings screen", in: app), 1)
    }
}

extension XCUIApplication {
    /// Waits until `condition` holds of the app.
    fileprivate func wait(for condition: @escaping (XCUIApplication) -> Bool, timeout: TimeInterval)
        -> Bool
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(self) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition(self)
    }
}
