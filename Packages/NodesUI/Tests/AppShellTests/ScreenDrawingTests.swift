import Nodes
import Testing

@testable import AppShell

@Suite(.serialized)
@MainActor
struct ScreenDrawingTests {
    @Test func aScreenDrawsOnTheMainThreadAndKeepsEverythingByDefault() {
        let screen = NodeScreen(Node(), title: "Plain")

        #expect(screen.drawingMode == .synchronous)
        #expect(screen.displayRange == nil)
    }

    @Test func screensMadeAfterTheDefaultsChangeTakeThem() {
        let before = (NodeScreen.defaultDrawingMode, NodeScreen.defaultDisplayRange)
        defer { (NodeScreen.defaultDrawingMode, NodeScreen.defaultDisplayRange) = before }

        NodeScreen.defaultDrawingMode = .asynchronous
        NodeScreen.defaultDisplayRange = DisplayRange(drawDistance: 2, releaseDistance: 4)
        let later = NodeScreen(Node())

        #expect(later.drawingMode == .asynchronous)
        #expect(later.displayRange == DisplayRange(drawDistance: 2, releaseDistance: 4))
    }

    @Test func aScreenCanBeToldItsOwnMode() {
        let screen = NodeScreen(Node())

        screen.drawingMode = .asynchronous

        #expect(screen.drawingMode == .asynchronous)
        #expect(NodeScreen.defaultDrawingMode == .synchronous)
    }

    @Test func theReleaseDistanceNeverFallsShortOfTheDrawDistance() {
        let range = DisplayRange(drawDistance: 3, releaseDistance: 1)

        #expect(range.releaseDistance == 3)
        #expect(DisplayRange(drawDistance: -1).drawDistance == 0)
    }
}
