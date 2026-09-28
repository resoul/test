#if canImport(UIKit)
    import AppShell
    import AppShellUIKit
    import LayoutCore
    import Nodes
    import NodesUIKit
    import StateCore
    import Testing
    import UIKit

    private enum Route: Hashable {
        case inbox
        case message
    }

    @MainActor
    private final class Leaf: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }
    }

    /// A button of the remote, pressed in a test.
    private final class Press: UIPress {
        let kind: UIPress.PressType

        init(_ kind: UIPress.PressType) {
            self.kind = kind
            super.init()
        }

        override var type: UIPress.PressType { kind }
    }

    @MainActor
    private func window(showing controller: UIViewController) -> UIWindow {
        // A presentation shows only in a window of a scene.
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// The package's test host starts a presentation's transition and never ends it: the tests
    /// check what the adapter asks of UIKit, and end the show themselves, as UIKit's
    /// completion does. The demo's UI tests show and close presentations for real.
    @Suite(.serialized)
    @MainActor
    struct UIKitPresentationTests {
        /// A stack in a window, whose root presents `presentation`; the presented controller.
        private func presenting(
            _ presentation: Presentation
        ) throws -> (Stack<Route>, Screen, UIViewController, UIWindow) {
            let stack = Stack(root: Route.inbox) { _ in NodeScreen(Leaf(), title: "Inbox") }
            let controller = stack.makeViewController()
            let window = window(showing: controller)
            let inbox = try #require(stack.screen(for: stack.presentedEntries[0]))
            #expect(inbox.present(presentation) == .accepted)
            let shown = try #require(controller.presentedViewController)
            return (stack, inbox, shown, window)
        }

        @Test
        func aPresentationIsPresentedOverTheStackInItsStyle() throws {
            let sheet = Presentation(NodeScreen(Leaf()))
            let (stack, _, shown, _) = try presenting(sheet)
            // A TV shows a sheet over the whole screen.
            let isTV = shown.traitCollection.userInterfaceIdiom == .tv
            #expect((shown.modalPresentationStyle == .fullScreen) == isTV)
            #expect(shown.presentationController?.delegate != nil)
            #expect(!shown.isModalInPresentation)
            sheet.isDismissible = false
            StateUpdates.flush()
            #expect(shown.isModalInPresentation)
            stack.close()

            let whole = Presentation(NodeScreen(Leaf()), style: .fullScreen)
            let (other, _, shownWhole, _) = try presenting(whole)
            #expect(shownWhole.modalPresentationStyle == .fullScreen)
            other.close()
        }

        @Test
        func aSheetSwipedDownAllTheWayIsDismissedAndOneHeldBackAsks() throws {
            let presentation = Presentation(NodeScreen(Leaf()))
            var attempts = 0
            presentation.onDismissAttempt = { attempts += 1 }
            let (stack, inbox, shown, _) = try presenting(presentation)
            presentation.showEnded(completed: true)
            let sheet = try #require(shown.presentationController)
            let delegate = try #require(sheet.delegate)

            #expect(delegate.presentationControllerShouldDismiss?(sheet) == true)
            presentation.isDismissible = false
            #expect(delegate.presentationControllerShouldDismiss?(sheet) == false)
            delegate.presentationControllerDidAttemptToDismiss?(sheet)
            #expect(attempts == 1)

            // UIKit reports a swipe down only when it went all the way.
            delegate.presentationControllerDidDismiss?(sheet)
            #expect(!presentation.isShown)
            #expect(inbox.presentation == nil)
            stack.close()
        }

        @Test
        func menuOverAControllerOfUIKitClosesThePresentationAsItSays() throws {
            let settings = UIViewController()
            let presentation = Presentation(ControllerScreen(settings), style: .fullScreen)
            var attempts = 0
            presentation.onDismissAttempt = { attempts += 1 }
            presentation.isDismissible = false
            let (stack, _, shown, _) = try presenting(presentation)
            presentation.showEnded(completed: true)
            shown.loadViewIfNeeded()
            #expect(settings.parent === shown)

            shown.pressesBegan([Press(.menu)], with: nil)
            #expect(attempts == 1)
            #expect(presentation.isWanted)
            presentation.isDismissible = true
            shown.pressesBegan([Press(.menu)], with: nil)
            #expect(!presentation.isWanted)
            stack.close()
        }

        @Test @available(tvOS, unavailable)
        func aSheetStopsAtItsHeightsAndFollowsTheUsersDrag() throws {
            let presentation = Presentation(
                NodeScreen(Leaf()),
                style: .sheet(heights: [.medium, .fraction(0.8), .large], usableBelow: .medium)
            )
            let (stack, _, shown, _) = try presenting(presentation)
            presentation.showEnded(completed: true)
            let sheet = try #require(shown.sheetPresentationController)
            #expect(sheet.detents.count == 3)
            #expect(sheet.prefersGrabberVisible)
            #expect(sheet.selectedDetentIdentifier == .medium)
            #expect(sheet.largestUndimmedDetentIdentifier == .medium)

            presentation.height = .large
            StateUpdates.flush()
            #expect(sheet.selectedDetentIdentifier == .large)

            sheet.selectedDetentIdentifier = .init("fraction.0.8")
            let delegate = try #require(sheet.delegate as? UISheetPresentationControllerDelegate)
            delegate.sheetPresentationControllerDidChangeSelectedDetentIdentifier?(sheet)
            #expect(presentation.height == .fraction(0.8))
            stack.close()
        }

        @Test
        func aSheetWithHeightsCoversTheScreenOfATV() throws {
            let presentation = Presentation(NodeScreen(Leaf()), style: .sheet(heights: [.medium]))
            let (stack, _, shown, _) = try presenting(presentation)
            let isTV = shown.traitCollection.userInterfaceIdiom == .tv
            #expect((shown.modalPresentationStyle == .fullScreen) == isTV)
            stack.close()
        }

        @Test
        func anAlertIsAnAlertControllerWithItsActions() throws {
            let stack = Stack(root: Route.inbox) { _ in NodeScreen(Leaf(), title: "Inbox") }
            let controller = stack.makeViewController()
            let first = window(showing: controller)
            let inbox = try #require(stack.screen(for: stack.presentedEntries[0]))
            let alert = Alert("Delete the message?", message: "It cannot be undone.") {
                AlertAction("Delete", role: .destructive)
                AlertAction.cancel
            }

            #expect(inbox.present(alert) == .accepted)
            let shown = try #require(controller.presentedViewController as? UIAlertController)
            #expect(shown.title == "Delete the message?")
            #expect(shown.message == "It cannot be undone.")
            #expect(shown.preferredStyle == .alert)
            #expect(shown.actions.map(\.style) == [.destructive, .cancel])
            _ = first
            stack.close()

            let other = Stack(root: Route.inbox) { _ in NodeScreen(Leaf(), title: "Inbox") }
            let otherController = other.makeViewController()
            let otherWindow = window(showing: otherController)
            let root = try #require(other.screen(for: other.presentedEntries[0]))
            root.present(Alert("Move to", style: .actions) { AlertAction("Archive") })
            let actions = try #require(
                otherController.presentedViewController as? UIAlertController
            )
            #expect(actions.preferredStyle == .actionSheet)
            _ = otherWindow
            other.close()
        }
    }
#endif
