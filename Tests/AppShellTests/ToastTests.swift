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
