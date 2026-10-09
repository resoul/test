import Network
import XCTest
import os

/// Background transfers across the app's endings (`BACKGROUND_PROBE`; see `BackgroundProbe`): a
/// download scheduled by one run of the app, answered by the server after that run has been ended, is
/// finished by the system, and the next run is given its outcome — and is given it again until
/// it acknowledges it.
final class BackgroundRelaunchTests: XCTestCase {
    /// Answers each request after `delay`, from the test's own process, which outlives the app's.
    private final class DelayedServer: Sendable {
        let listener: NWListener
        let port: UInt16
        private let answers = OSAllocatedUnfairLock(initialState: 0)

        var hasAnswered: Bool { answers.withLock { $0 > 0 } }

        init(delay: TimeInterval, body: Data, served: XCTestExpectation) throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = XCTestExpectation(description: "listening")
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.fulfill() }
            }
            let answers = answers
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        let head =
                            "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n"
                            + "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
                        connection.send(
                            content: Data(head.utf8) + body,
                            contentContext: .finalMessage,
                            completion: .contentProcessed { _ in
                                answers.withLock { $0 += 1 }
                                served.fulfill()
                                connection.cancel()
                            }
                        )
                    }
                }
            }
            listener.start(queue: .global())
            XCTWaiter().wait(for: [ready], timeout: 10)
            port = listener.port?.rawValue ?? 0
        }
    }

    @MainActor
    func testADownloadScheduledByOneRunIsFinishedWhileTheAppIsEndedAndDeliveredToTheNextRun() throws
    {
        continueAfterFailure = false
        let served = expectation(description: "the server answered")
        let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let server = try DelayedServer(delay: 8, body: body, served: served)
        XCTAssertNotEqual(server.port, 0)
        let app = XCUIApplication()
        app.launchEnvironment["BACKGROUND_PROBE"] = "1"
        app.launchEnvironment["BACKGROUND_RESET"] = "1"
        app.launchEnvironment["BACKGROUND_SCHEDULE"] = "1"
        app.launchEnvironment["BACKGROUND_URL"] = "http://127.0.0.1:\(server.port)/probe.bin"

        // First run: schedules the download, sees it running, and is ended before the server answers.
        app.launch()
        XCTAssertTrue(app.staticTexts["running: 1"].waitForExistence(timeout: 60))
        // Nothing has come back yet, so what the next run is given is not something this one saw.
        XCTAssertTrue(app.staticTexts["outcome: none"].exists)
        XCTAssertFalse(server.hasAnswered, "answered too soon")
        app.terminate()

        // The server answers with no app running.
        wait(for: [served], timeout: 60)
        withExtendedLifetime(server) {}

        // Second run: the system has finished the transfer, and the outcome is delivered. The system
        // may start the app itself to report, and launching it at that very moment fails; it is given
        // time to settle.
        Thread.sleep(forTimeInterval: 8)
        app.launchEnvironment["BACKGROUND_RESET"] = nil
        app.launchEnvironment["BACKGROUND_SCHEDULE"] = nil
        app.launch()
        let outcome = "outcome: relaunch-probe status=200 bytes=200000 failure=none"
        XCTAssertTrue(
            app.staticTexts[outcome].waitForExistence(timeout: 60),
            "screen: \(String(app.debugDescription.prefix(3000)))"
        )
        XCTAssertTrue(app.staticTexts["running: 0"].exists)

        // Not acknowledged: the next run is given it again.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[outcome].waitForExistence(timeout: 60))
        app.buttons["Acknowledge"].tap()
        XCTAssertTrue(app.staticTexts["outcome: acknowledged"].waitForExistence(timeout: 10))
        app.terminate()

        // Acknowledged: nothing is left.
        app.launch()
        XCTAssertTrue(app.staticTexts["running: 0"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["outcome: none"].exists)
        XCTAssertFalse(app.staticTexts[outcome].exists)
    }
}
