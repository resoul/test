#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import AppShell
    import Nodes
    import StateCore
    import Testing

    @testable import AppShellAppKit

    @MainActor
    private struct ToastApp: Application {
        init() {}

        var scenes: [WindowScene] {
            WindowScene("main") { NodeScreen(Node()) }
        }
    }

    @MainActor
    private func overlay() throws -> (ToastOverlay, SceneSession) {
        let shell = Shell(application: ToastApp())
        let session = try #require(shell.makeSession())
        let overlay = ToastOverlay(session: session)
        overlay.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return (overlay, session)
    }

    @Test @MainActor
    func aToastShowsItsWordsAndItsActionAndTheActionIsCarriedOutOnce() throws {
        let (overlay, session) = try overlay()
        #expect(overlay.pill == nil)

        var undone = 0
        session.show(Toast("Message deleted", action: ToastAction("Undo") { undone += 1 }))
        StateUpdates.flush()
        let pill = try #require(overlay.pill)
        #expect(pill.label.stringValue == "Message deleted")
        #expect(pill.actionButton.title == "Undo")
        #expect(pill.superview === overlay)

        pill.actionTapped()
        #expect(undone == 1)
        StateUpdates.flush()
        #expect(session.shownToast == nil)
    }

    @Test @MainActor
    func aToastWithoutAnActionHasNoActionButtonAndTheNextReplacesIt() throws {
        let (overlay, session) = try overlay()

        session.show(Toast("Saved"))
        StateUpdates.flush()
        let first = try #require(overlay.pill)
        #expect(first.actionButton.superview == nil)

        session.show(Toast("Archived"))
        StateUpdates.flush()
        let second = try #require(overlay.pill)
        #expect(second !== first)
        #expect(second.label.stringValue == "Archived")

        // The button that closes it, in any toast.
        second.closed()
        StateUpdates.flush()
        #expect(overlay.pill == nil)
        #expect(session.shownToast == nil)
    }

    @MainActor
    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(
            NSEvent.enterExitEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
    }

    @Test @MainActor
    func theMouseOnAToastHoldsItAndOnlyTheToastTakesTheMouse() async throws {
        let (overlay, session) = try overlay()
        session.show(Toast("Held", duration: 0.3))
        StateUpdates.flush()
        let pill = try #require(overlay.pill)

        // Outside the toast the mouse goes to the view under.
        #expect(overlay.hitTest(NSPoint(x: 5, y: 5)) == nil)

        pill.mouseEntered(with: try crossing(.mouseEntered))
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(session.shownToast != nil, "held: it stays past its time")

        pill.mouseExited(with: try crossing(.mouseExited))
        try await Task.sleep(nanoseconds: 1_400_000_000)
        #expect(session.shownToast == nil, "let go: it goes")
    }
#endif
