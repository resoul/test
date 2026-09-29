#if canImport(UIKit)
    import AppShell
    import Nodes
    import StateCore
    import Testing
    import UIKit

    @testable import AppShellUIKit

    @MainActor
    private struct ToastApp: Application {
        init() {}

        var scenes: [WindowScene] {
            WindowScene("main") { NodeScreen(Node()) }
        }
    }

    @MainActor
    private func controller() throws -> (ToastController, SceneSession) {
        let shell = Shell(application: ToastApp())
        let session = try #require(shell.makeSession())
        let controller = ToastController(session: session)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        controller.loadViewIfNeeded()
        return (controller, session)
    }

    @Test @MainActor
    func aToastShowsItsWordsAndItsActionAndTheActionIsCarriedOutOnce() throws {
        let (controller, session) = try controller()
        #expect(controller.pill == nil)

        var undone = 0
        session.show(Toast("Message deleted", action: ToastAction("Undo") { undone += 1 }))
        StateUpdates.flush()
        let pill = try #require(controller.pill)
        #expect(pill.label.text == "Message deleted")
        #expect(pill.actionButton.title(for: .normal) == "Undo")
        #expect(pill.superview === controller.view)

        // A TV has no button to take the action with; elsewhere the button does.
        if UIDevice.current.userInterfaceIdiom != .tv {
            #expect(pill.actionButton.superview != nil)
            pill.actionTapped()
            #expect(undone == 1)
            StateUpdates.flush()
            #expect(session.shownToast == nil)
        }
    }

    @Test @MainActor
    func aToastWithoutAnActionHasNoButtonAndTheNextReplacesIt() throws {
        let (controller, session) = try controller()

        session.show(Toast("Saved"))
        StateUpdates.flush()
        let first = try #require(controller.pill)
        #expect(first.actionButton.superview == nil)

        session.show(Toast("Archived"))
        StateUpdates.flush()
        let second = try #require(controller.pill)
        #expect(second !== first)
        #expect(second.label.text == "Archived")

        session.dismissToast()
        StateUpdates.flush()
        #expect(controller.pill == nil)
    }

    @Test @MainActor
    func theSameToastAskedForAgainIsTheSameView() throws {
        let (controller, session) = try controller()

        session.show(Toast("Saved"))
        StateUpdates.flush()
        let pill = try #require(controller.pill)
        session.show(Toast("Saved"))
        StateUpdates.flush()
        #expect(controller.pill === pill)
    }
#endif
