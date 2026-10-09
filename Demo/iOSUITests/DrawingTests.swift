import CoreGraphics
import XCTest

/// Text drawn in the background and kept only near the screen (`DRAWING_PROBE`; see
/// `DrawingProbe`), and a list that tells what it prefetched.
final class DrawingTests: XCTestCase {
    /// How many pixels in the middle of the screen are dark: ink of text on a light page.
    @MainActor
    private func ink(_ app: XCUIApplication) -> Int {
        guard let image = app.screenshot().image.cgImage else { return 0 }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0
        for row in stride(from: height / 4, to: height * 3 / 4, by: 2) {
            for column in stride(from: 0, to: width, by: 2) {
                let offset = (row * width + column) * 4
                if pixels[offset] < 100, pixels[offset + 1] < 100, pixels[offset + 2] < 100 {
                    count += 1
                }
            }
        }
        return count
    }

    @MainActor
    func testTextDrawnInTheBackgroundShowsAndKeepsShowingWhileScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DRAWING_PROBE"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Line 0"].waitForExistence(timeout: 60))
        // The bitmaps come a moment after the nodes.
        let deadline = Date().addingTimeInterval(10)
        while ink(app) < 200, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(ink(app), 200, "the first lines are drawn")

        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        let after = Date().addingTimeInterval(10)
        while ink(app) < 200, Date() < after { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(ink(app), 200, "lines far from the first ones are drawn when they come near")
        XCTAssertFalse(app.staticTexts["Line 0"].isHittable)

        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        let back = Date().addingTimeInterval(10)
        while ink(app) < 200, Date() < back { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(ink(app), 200, "released lines are drawn again when they come back")
    }

    @MainActor
    func testAListTellsWhatItPrefetchedAndCalledOff() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DRAWING_PROBE"] = "lazy"
        app.launch()

        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'announced:'"))
            .firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60))
        XCTAssertFalse(status.label.hasPrefix("announced: 0 "), status.label)
        XCTAssertTrue(status.label.hasSuffix("called off: 0"), status.label)

        for _ in 0..<25 { app.swipeUp(velocity: .fast) }
        let calledOff = NSPredicate(
            format: "label BEGINSWITH 'announced:' AND NOT (label ENDSWITH 'called off: 0')"
        )
        XCTAssertTrue(
            app.staticTexts.matching(calledOff).firstMatch.waitForExistence(timeout: 20),
            "texts: \(app.staticTexts.allElementsBoundByIndex.map(\.label).prefix(5))"
        )
    }
}
