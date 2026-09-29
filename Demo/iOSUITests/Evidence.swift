import XCTest

extension XCTestCase {
    /// Keeps what the screen and the accessibility tree show, in the result of the run, whether
    /// or not the test fails afterwards: a failure of a UI test on a slow machine is judged from
    /// this, not from a rerun that passes.
    @MainActor
    func attachEvidence(_ name: String, of app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) - screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) - accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// Waits until `condition` holds and returns the seconds it took, or `nil` after `timeout`
    /// seconds, with the evidence attached and the failure named after the stage.
    @MainActor
    @discardableResult
    func stage(
        _ name: String,
        of app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) -> TimeInterval? {
        let began = Date()
        while !condition() {
            if Date().timeIntervalSince(began) > timeout {
                attachEvidence(name, of: app)
                XCTFail("\(name): not reached in \(timeout) s", file: file, line: line)
                return nil
            }
            usleep(50_000)
        }
        let took = Date().timeIntervalSince(began)
        let note = XCTAttachment(string: String(format: "%@: %.2f s", name, took))
        note.name = "\(name) - time"
        note.lifetime = .keepAlways
        add(note)
        return took
    }
}
