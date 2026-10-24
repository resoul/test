import XCTest

final class ComparisonTests: XCTestCase {
    @MainActor
    private func launch(engine: String = "uikit") -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["COMPARISON_ROWS"] = "100"
        app.launchEnvironment["COMPARISON_ENGINE"] = engine
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["UIKit"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func containing(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    @MainActor
    private func isOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let rect = element.frame
        return !rect.isEmpty && rect.intersects(app.frame)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testTheTwoControllersShowTheSameFeedAndScrollIndependently() {
        let app = launch()
        let title = "Запись 1. Там, где начинается утро"
        XCTAssertTrue(app.tables["native-feed"].waitForExistence(timeout: 10))
        XCTAssertTrue(containing(title, in: app).waitForExistence(timeout: 10))
        attach(app, name: "UIKit-profile")
        app.collectionViews["native-albums"].swipeLeft()
        XCTAssertFalse(
            app.collectionViews["native-albums"].staticTexts["Казбеги, Грузия"].isHittable
        )
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        XCTAssertFalse(isOnScreen(containing(title, in: app), in: app))
        attach(app, name: "UIKit-feed")

        app.tabBars.buttons["Nodes"].tap()
        XCTAssertTrue(app.otherElements["node-feed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Анна Лесная"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(containing(title, in: app).waitForExistence(timeout: 20))
        attach(app, name: "Nodes-profile")
        let shelf = app.staticTexts["Избранные маршруты"]
        XCTAssertTrue(shelf.isHittable)
        let y = shelf.frame.maxY + 50
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: app.frame.width - 35, dy: y)
        )
        .press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 35, dy: y))
        )
        XCTAssertFalse(isOnScreen(app.staticTexts["Казбеги, Грузия"].firstMatch, in: app))
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        XCTAssertFalse(isOnScreen(containing(title, in: app), in: app))
        XCTAssertTrue(containing("Запись ", in: app).exists)
        attach(app, name: "Nodes-feed")

        app.tabBars.buttons["UIKit"].tap()
        XCTAssertFalse(isOnScreen(containing(title, in: app), in: app))
    }

    @MainActor
    func testTheLoadMenuRebuildsBothListsAndRotationKeepsContent() {
        let app = launch(engine: "nodes")
        XCTAssertTrue(app.staticTexts["Лента · 100 записей"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["feed-options"].tap()
        app.buttons["2000 записей"].tap()
        XCTAssertTrue(app.staticTexts["Лента · 2000 записей"].waitForExistence(timeout: 15))
        for _ in 0..<8 { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(containing("Запись ", in: app).exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(containing("Запись ", in: app).waitForExistence(timeout: 10))
        attach(app, name: "Nodes-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.tabBars.buttons["UIKit"].tap()
        XCTAssertTrue(app.staticTexts["Лента · 2000 записей"].waitForExistence(timeout: 15))
        attach(app, name: "UIKit-2000")
    }

    @MainActor
    func testSavedStateIsSharedBetweenControllers() {
        let app = launch()
        let save = app.buttons["save-0"]
        for _ in 0..<3 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(app.buttons["Сохранено ✓"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Nodes"].tap()
        XCTAssertTrue(containing("Сохранено ✓", in: app).waitForExistence(timeout: 20))
    }
}
