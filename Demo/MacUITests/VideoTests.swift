import XCTest

/// The video node (`VIDEO_PROBE`; see `VideoProbe`): nothing plays until asked, playing shows
/// the picture and runs to the end, and a video that cannot be opened says so and offers Retry.
final class VideoTests: XCTestCase {
    @MainActor
    func testAVideoPlaysWhenAskedAndABrokenOneOffersRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VIDEO_PROBE"] = "1"
        app.launch()

        // The probe writes its video a moment after launch; until it does there is no source.
        XCTAssertTrue(
            app.staticTexts["Video: idle paused frame:false"].waitForExistence(timeout: 30),
            "nothing plays until asked"
        )
        app.buttons["Play"].click()
        XCTAssertTrue(
            app.staticTexts["Video: ready ended frame:true"].waitForExistence(timeout: 30),
            "the video shows its picture and runs to the end; texts: "
                + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )

        app.buttons["Play broken"].click()
        // The video is one element: its value tells the failure, and Retry is its action.
        let broken = app.descendants(matching: .any)["Broken video"]
        XCTAssertTrue(broken.waitForExistence(timeout: 10), "the broken video is an element")
        let told = NSPredicate(format: "value == 'Failed. The video file could not be read.'")
        expectation(for: told, evaluatedWith: broken)
        waitForExpectations(timeout: 20)
    }

    /// Making the window bigger changes the tree's size: the video is as wide as the
    /// window's content in both sizes and keeps its proportions.
    @MainActor
    func testTheVideoFollowsTheWindowWhenItIsResized() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VIDEO_PROBE"] = "1"
        app.launch()

        let video = app.descendants(matching: .any)["Sample video"]
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        let window = app.windows.firstMatch
        let before = video.frame
        let windowBefore = window.frame
        XCTAssertEqual(before.width / before.height, 16.0 / 9.0, accuracy: 0.03)

        // The window is made bigger with Window > Zoom (a drag of the window's edge is not
        // taken by the test runner here).
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        let wider = NSPredicate { _, _ in window.frame.width > windowBefore.width + 100 }
        expectation(for: wider, evaluatedWith: nil)
        waitForExpectations(timeout: 10)

        let after = video.frame
        XCTAssertGreaterThan(after.width, before.width + 100, "wider with the window")
        XCTAssertEqual(after.width / after.height, 16.0 / 9.0, accuracy: 0.03, "proportions kept")
        XCTAssertLessThanOrEqual(after.maxX, window.frame.maxX + 0.5, "inside the window")

        // And back: Zoom again returns the window, and the video shrinks with it.
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Zoom"].click()
        let smaller = NSPredicate { _, _ in window.frame.width < windowBefore.width + 20 }
        expectation(for: smaller, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(video.frame.width, before.width, accuracy: 20, "back to its first width")
    }
}
