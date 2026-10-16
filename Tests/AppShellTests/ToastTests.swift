import Foundation
import Nodes
import Testing

@testable import AppShell

@MainActor
private struct ToastApp: Application {
    init() {}

    var scenes: [WindowScene] {
        WindowScene("main") { NodeScreen(Node()) }
    }
}

@MainActor
private func session() throws -> (Shell, SceneSession) {
    let shell = Shell(application: ToastApp())
    return (shell, try #require(shell.makeSession()))
}

private func wait(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@Test @MainActor
func aToastShowsAndTheNextTakesItsPlaceWhileTheSameOneOnlyStaysLonger() throws {
    let (_, window) = try session()
    #expect(window.shownToast == nil)

    window.show(Toast("Message deleted"))
    let first = try #require(window.shownToast)
    #expect(first.toast.message == "Message deleted")

    // The same message asked for again is that toast: the same one, kept on.
    window.show(Toast("Message deleted"))
    #expect(window.shownToast?.id == first.id)

    // Another takes its place.
    window.show(Toast("Message archived"))
    let second = try #require(window.shownToast)
    #expect(second.id != first.id)
    #expect(second.toast.message == "Message archived")

    // The same words with a different action are another toast.
    window.show(Toast("Message archived", action: ToastAction("Undo") {}))
    #expect(window.shownToast?.id != second.id)
    window.dismissToast()
    #expect(window.shownToast == nil)
}

@Test @MainActor
func aToastGoesByItselfAfterItsTimeAndNotBeforeAnAnotherStartsItsOwn() async throws {
    let (_, window) = try session()

    window.show(Toast("Short", duration: 0.15))
    #expect(window.shownToast != nil)
    await wait(0.4)
    #expect(window.shownToast == nil)

    // A new toast has its own time: the first one's timer does not take it away.
    window.show(Toast("First", duration: 0.2))
    await wait(0.1)
    window.show(Toast("Second", duration: 0.5))
    await wait(0.3)
    #expect(window.shownToast?.toast.message == "Second")
    await wait(0.5)
    #expect(window.shownToast == nil)
}

@Test @MainActor
func theUsualTimeIsFourSecondsAndEightWithAnAction() {
    #expect(Toast("A").seconds == 4)
    #expect(Toast("A", action: ToastAction("Undo") {}).seconds == 8)
    #expect(Toast("A", duration: 1.5).seconds == 1.5)
}

@Test @MainActor
func aPersistentToastStaysUntilItIsClosed() async throws {
    let (_, window) = try session()

    window.show(Toast("Could not save", duration: 0.1, persistent: true))
    await wait(0.4)
    #expect(window.shownToast != nil)
    window.dismissToast()
    #expect(window.shownToast == nil)
}

@Test @MainActor
func theActionIsCarriedOutOnceAndTheToastGoes() throws {
    let (_, window) = try session()
    var undone = 0
    window.show(Toast("Message deleted", action: ToastAction("Undo") { undone += 1 }))

    window.performToastAction()
    #expect(undone == 1)
    #expect(window.shownToast == nil)
    // Nothing is left to take it with a second time.
    window.performToastAction()
    #expect(undone == 1)

    // A toast without an action has nothing to carry out.
    window.show(Toast("Saved"))
    window.performToastAction()
    #expect(window.shownToast != nil)
}

@Test @MainActor
func aHeldToastStaysAndAReleasedOneGoesOnToItsEnd() async throws {
    let (_, window) = try session()

    window.show(Toast("Held", duration: 0.6))
    await wait(0.1)
    window.holdToast()
    await wait(0.8)
    #expect(window.shownToast != nil, "held: it stays past its time")

    window.resumeToast()
    await wait(0.2)
    #expect(window.shownToast != nil, "released: it has time left")
    await wait(0.8)
    #expect(window.shownToast == nil)
}

@Test @MainActor
func theShellShowsAToastInTheActiveWindowAndSaysWhenThereIsNone() throws {
    let shell = Shell(application: ToastApp())
    #expect(!shell.toast(Toast("No window")))

    let first = try #require(shell.makeSession())
    let second = try #require(shell.makeSession())
    #expect(shell.toast(Toast("First window")))
    #expect(first.shownToast?.toast.message == "First window")

    second.setActivation(.active)
    #expect(shell.toast(Toast("Active window")))
    #expect(second.shownToast?.toast.message == "Active window")
    #expect(first.shownToast?.toast.message == "First window")

    // A window closed for good takes its toast with it.
    shell.sessionClosed(second)
    #expect(second.shownToast == nil)
}

@Test @MainActor
func toastsOfOneGroupAreOneThatCountsThemAndUndoesTheNewestFirst() throws {
    let (_, window) = try session()
    var undone: [Int] = []
    func deleted(_ number: Int) -> Toast {
        Toast(
            "Message deleted",
            action: ToastAction("Undo") { undone.append(number) },
            group: "deleted",
            counted: { "\($0) messages deleted" }
        )
    }

    window.show(deleted(1))
    let first = try #require(window.shownToast)
    #expect(first.count == 1)
    #expect(first.message == "Message deleted")

    window.show(deleted(2))
    window.show(deleted(3))
    let joined = try #require(window.shownToast)
    #expect(joined.id == first.id, "the same toast, shown in place")
    #expect(joined.count == 3)
    #expect(joined.message == "3 messages deleted")

    window.performToastAction()
    #expect(undone == [3, 2, 1])
    #expect(window.shownToast == nil)

    // Another group is another toast; without `counted` the newest words show.
    window.show(Toast("Archived 1", group: "archived"))
    let archived = try #require(window.shownToast)
    window.show(Toast("Archived 2", group: "archived"))
    #expect(window.shownToast?.id == archived.id)
    #expect(window.shownToast?.message == "Archived 2")
    window.show(Toast("Message deleted", group: "deleted"))
    #expect(window.shownToast?.id != archived.id)
}

@Test @MainActor
func aJoinedToastKeepsAnActionAndStaysPersistentIfEitherWas() throws {
    let (_, window) = try session()
    var undone = 0
    window.show(
        Toast("Could not send", action: ToastAction("Retry") { undone += 1 }, group: "send")
    )
    window.show(Toast("Could not send", persistent: true, group: "send"))

    let joined = try #require(window.shownToast)
    #expect(joined.toast.action?.title == "Retry")
    #expect(joined.toast.isPersistent)
    window.performToastAction()
    #expect(undone == 1)
}

@Test @MainActor
func aHeldToastStaysHeldWhenAnotherJoinsIt() async throws {
    let (_, window) = try session()
    window.show(Toast("Deleted", duration: 0.3, group: "deleted"))
    window.holdToast()
    window.show(Toast("Deleted", duration: 0.3, group: "deleted"))
    await wait(0.6)
    #expect(window.shownToast != nil, "the finger is still on it")

    window.resumeToast()
    await wait(0.6)
    #expect(window.shownToast == nil)
}

@Test @MainActor
func aQueueingShellShowsToastsOneAfterAnotherAndJoinsTheWaitingOnes() async throws {
    let (shell, window) = try session()
    shell.toastQueueing = .queue

    window.show(Toast("First", duration: 0.2))
    window.show(Toast("Second", duration: 5))
    window.show(Toast("Deleted 1", group: "deleted", counted: { "\($0) deleted" }))
    window.show(Toast("Deleted 2", group: "deleted", counted: { "\($0) deleted" }))
    // The same words without a group are the waiting toast again, not one more.
    window.show(Toast("Second", duration: 5))
    #expect(window.shownToast?.message == "First")
    #expect(window.queuedToasts.map(\.message) == ["Second", "2 deleted"])

    // The first goes by itself and the next comes in its place.
    await wait(0.4)
    #expect(window.shownToast?.message == "Second")
    #expect(window.queuedToasts.map(\.message) == ["2 deleted"])

    // Closing one shows the next; taking its action too.
    window.dismissToast()
    #expect(window.shownToast?.message == "2 deleted")
    #expect(window.queuedToasts.isEmpty)
    window.dismissToast()
    #expect(window.shownToast == nil)

    var undone = 0
    window.show(Toast("A", action: ToastAction("Undo") { undone += 1 }))
    window.show(Toast("B"))
    window.performToastAction()
    #expect(undone == 1)
    #expect(window.shownToast?.message == "B")

    // Everything goes at once, and with the window.
    window.show(Toast("C"))
    window.dismissAllToasts()
    #expect(window.shownToast == nil)
    #expect(window.queuedToasts.isEmpty)
    window.show(Toast("D"))
    window.show(Toast("E"))
    shell.sessionClosed(window)
    #expect(window.shownToast == nil)
    #expect(window.queuedToasts.isEmpty)
}

@Test @MainActor
func aPersistentToastHoldsTheQueueUntilItIsClosed() async throws {
    let (shell, window) = try session()
    shell.toastQueueing = .queue

    window.show(Toast("Could not save", persistent: true))
    window.show(Toast("Saved", duration: 0.1))
    await wait(0.3)
    #expect(window.shownToast?.message == "Could not save")
    window.dismissToast()
    #expect(window.shownToast?.message == "Saved")
}

@Test @MainActor
func withoutTheQueueANewToastStillReplacesTheShownOne() throws {
    let (shell, window) = try session()
    #expect(shell.toastQueueing == .replace)

    window.show(Toast("First"))
    window.show(Toast("Second"))
    #expect(window.shownToast?.message == "Second")
    #expect(window.queuedToasts.isEmpty)
}
