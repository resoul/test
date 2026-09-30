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
}
