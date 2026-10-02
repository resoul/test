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
        app.buttons["Play"].tap()
        XCTAssertTrue(
            app.staticTexts["Video: ready ended frame:true"].waitForExistence(timeout: 30),
            "the video shows its picture and runs to the end; texts: "
                + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )

        app.buttons["Play broken"].tap()
        // The video is one element: its value tells the failure, and Retry is its action.
        let broken = app.otherElements["Broken video"]
        XCTAssertTrue(broken.waitForExistence(timeout: 10), "the broken video is an element")
        let told = NSPredicate(format: "value == 'Failed. The video file could not be read.'")
        expectation(for: told, evaluatedWith: broken)
        waitForExpectations(timeout: 20)
    }

    /// Turning the device changes the size of the tree: the video is as wide as the screen in
    /// both positions, keeps its proportions, and stays inside the screen.
    @MainActor
    func testTheVideoFollowsTheScreenWhenTheDeviceTurns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VIDEO_PROBE"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }

        let video = app.otherElements["Sample video"]
        XCTAssertTrue(video.waitForExistence(timeout: 30))
        let portrait = video.frame
        let screenWidth = app.windows.firstMatch.frame.width
        XCTAssertEqual(portrait.width / portrait.height, 16.0 / 9.0, accuracy: 0.03)
        XCTAssertLessThanOrEqual(portrait.maxX, screenWidth + 0.5)

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in
            let frame = video.frame
            let width = app.windows.firstMatch.frame.width
            return width > screenWidth && frame.width > portrait.width
        }
        expectation(for: landscape, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        let turned = video.frame
        let width = app.windows.firstMatch.frame.width
        XCTAssertEqual(turned.width / turned.height, 16.0 / 9.0, accuracy: 0.03, "proportions kept")
        XCTAssertLessThanOrEqual(turned.maxX, width + 0.5, "inside the screen")
        XCTAssertGreaterThan(turned.width, width * 0.5, "it uses the room")
    }

    /// With `preload` the first picture is ready before play is asked for: the status line says the
    /// picture shows while the video is still paused, and play then goes to the end.
    @MainActor
    func testAPreparedVideoShowsItsPictureBeforePlayIsAskedFor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VIDEO_PROBE"] = "1"
        app.launchEnvironment["VIDEO_PRELOAD"] = "automatic"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Video: ready paused frame:true"].waitForExistence(timeout: 60),
            "the picture is ready with no Play; texts: "
                + "\(app.staticTexts.allElementsBoundByIndex.map { $0.label })"
        )
        app.buttons["Play"].tap()
        XCTAssertTrue(
            app.staticTexts["Video: ready ended frame:true"].waitForExistence(timeout: 30),
            "texts: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })"
        )
    }
}
