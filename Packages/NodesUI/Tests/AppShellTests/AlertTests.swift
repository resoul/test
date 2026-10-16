import Nodes
import StateCore
import Testing

@testable import AppShell

/// Shows and hides at once.
@MainActor
private final class AtOnce: PresentationPresenter {
    var hidden = 0

    func show(_ presentation: Presentation) {
        presentation.showEnded(completed: true)
    }

    func hide(_ presentation: Presentation) {
        hidden += 1
        presentation.hideEnded()
    }
}

@Test @MainActor
func anAlertHasOneCancelActionAndAnOKWithoutActions() {
    let alert = Alert("Delete?") {
        AlertAction("Delete", role: .destructive)
        AlertAction.cancel
        AlertAction("Later", role: .cancel)
    }
    #expect(alert.actions.map(\.role) == [.destructive, .cancel, .normal])
    #expect(alert.cancelIndex == 1)
    #expect(Alert("Saved").actions.map(\.title) == ["OK"])
    #expect(Alert("Saved").cancelIndex == nil)
}

@Test @MainActor
func choosingAnActionClosesTheAlertAndDoesIt() throws {
    let screen = NodeScreen(Node())
    let presenter = AtOnce()
    screen.presentationPresenter = presenter
    var done: [String] = []
    let alert = Alert("Delete?", message: "It cannot be undone.") {
        AlertAction("Delete", role: .destructive) { done.append("delete") }
        AlertAction("Cancel", role: .cancel) { done.append("cancel") }
    }

    #expect(screen.present(alert) == .accepted)
    #expect(screen.present(alert) == .rejected(.alreadyPresenting))
    #expect(try #require(screen.presentation).isShown)
    alert.choose(0)
    #expect(done == ["delete"])
    #expect(screen.presentation == nil)
    // The platform closed it: nothing to hide.
    #expect(presenter.hidden == 0)
    // Closed, it chooses nothing more, and shows once.
    alert.choose(1)
    #expect(done == ["delete"])
    #expect(NodeScreen(Node()).present(alert) == .rejected(.screenInUse))
}

@Test @MainActor
func escapeChoosesTheCancelActionAndAnAlertWithoutOneStays() throws {
    let screen = NodeScreen(Node())
    let presenter = AtOnce()
    screen.presentationPresenter = presenter
    var cancelled = 0
    let alert = Alert("Delete?") {
        AlertAction("Delete", role: .destructive)
        AlertAction("Cancel", role: .cancel) { cancelled += 1 }
    }
    screen.present(alert)
    #expect(alert.perform(.cancel))
    #expect(cancelled == 1)
    #expect(screen.presentation == nil)

    let notice = Alert("Saved")
    screen.present(notice)
    let presentation = try #require(screen.presentation)
    #expect(!presentation.isDismissible)
    notice.perform(.cancel)
    notice.perform(.back)
    #expect(presentation.isShown)
    // Taken away, it chooses nothing.
    notice.dismiss()
    #expect(!presentation.isShown)
    #expect(presenter.hidden == 1)
}
