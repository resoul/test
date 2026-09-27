import XCTest

/// The remote past a block with nothing to focus, on `FocusProbe` screens (`TV/FocusProbe`):
/// from the top button down to the bottom one — it shows, and Select presses it — down again
/// at the end, where the focus stays, and back up. `PROBES` in the test runner's environment
/// (`TEST_RUNNER_PROBES`), separated by `|`, replaces the screens tried.
final class FocusReachTests: XCTestCase {
    @MainActor
    func testTheRemoteReachesAButtonPastATallBlock() {
        let probes =
            ProcessInfo.processInfo.environment["PROBES"].map { $0.split(separator: "|").map(String.init) }
            ?? [
                // In the strip under the top button, further than the focus system looks.
                "block=5;column=same;section=0",
                // Beside the strip, over a block three screens tall.
                "block=3;column=other;section=0",
                // A section across the screen, which the focus system scrolls past.
                "block=3;column=same;section=1",
                // At the end of a scroll across, inside the scroll down.
                "block=3;column=other;section=0;inner=1",
            ]
        var failures: [String] = []
        for settings in probes {
            failures += probe(settings, fast: false)
        }
        // Presses one right after another: the moves the view makes do not pile up.
        failures += probe("block=3;column=other;section=0", fast: true)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Goes down and back up on the screen `settings` sets up; returns what went wrong.
    @MainActor
    private func probe(_ settings: String, fast: Bool) -> [String] {
        let app = XCUIApplication()
        app.launchEnvironment["FOCUS_PROBE"] = settings
        app.launch()
        defer { app.terminate() }
        guard app.buttons["Top"].waitForExistence(timeout: 20) else { return ["\(settings): no screen"] }

        let screen = app.windows.firstMatch.frame
        let top = app.buttons["Top"]
        let bottom = app.buttons["Bottom"]
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            if !ok {
                failures.append("\(settings)\(fast ? " fast" : ""): \(what)")
            }
        }
        sleep(1)
        if fast {
            for _ in 0..<3 {
                XCUIRemote.shared.press(.down)
            }
        } else {
            XCUIRemote.shared.press(.down)
        }
        sleep(2)
        check(screen.contains(bottom.frame), "the bottom button shows (\(bottom.frame))")
        XCUIRemote.shared.press(.select)
        check(app.staticTexts["Pressed: Bottom 1"].waitForExistence(timeout: 2), "down, Select presses the bottom button")
        // Nothing further down: the focus stays.
        XCUIRemote.shared.press(.down)
        sleep(2)
        XCUIRemote.shared.press(.select)
        check(app.staticTexts["Pressed: Bottom 2"].waitForExistence(timeout: 2), "at the end the focus stays")
        XCUIRemote.shared.press(.up)
        sleep(2)
        check(screen.contains(top.frame), "the top button shows (\(top.frame))")
        XCUIRemote.shared.press(.select)
        check(app.staticTexts["Pressed: Top 1"].waitForExistence(timeout: 2), "up, Select presses the top button")
        print("PROBERESULT \(settings)\(fast ? " fast" : ""): \(failures.isEmpty ? "ok" : failures.joined(separator: "; "))")
        return failures
    }
}
