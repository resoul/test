#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Marker: Node {}

    @MainActor
    private final class Form: Node {
        let name = TextField(placeholder: "Name")
        let notes = TextEditor(placeholder: "Notes")
        let email = TextField(placeholder: "Email", content: .email)
        let custom = Marker()

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                name
                notes
                email
            }
        }
    }

    @MainActor
    private func view(of form: Form) -> NodeView {
        let view = NodeView(root: form)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    /// The tree a keyboard bar holds, if the view has one.
    @MainActor
    private func bar(of responder: UIResponder?) -> NodeView? {
        let accessory =
            (responder as? UITextField)?.inputAccessoryView
            ?? (responder as? UITextView)?.inputAccessoryView
        return accessory?.subviews.compactMap { $0 as? NodeView }.first
    }

    @Test @MainActor
    func withoutABarTheKeyboardHasNoneAndASetOneIsEveryFieldsUnlessItSaysOtherwise() throws {
        let plain = Form()
        let plainView = view(of: plain)
        #expect(bar(of: plainView.embeddedView(of: plain.name.id)) == nil)
        plainView.host.detach()

        let form = Form()
        form.keyboardBar = .navigation
        form.email.keyboardBar = KeyboardBar.none
        let view = view(of: form)

        let name = try #require(bar(of: view.embeddedView(of: form.name.id)))
        #expect(name.root is KeyboardNavigationBar)
        #expect(bar(of: view.embeddedView(of: form.notes.id))?.root is KeyboardNavigationBar)
        #expect(bar(of: view.embeddedView(of: form.email.id)) == nil)
        // A tree for each: it cannot be in two.
        let notes = try #require(bar(of: view.embeddedView(of: form.notes.id)))
        #expect(name.root !== notes.root)
        view.host.detach()
    }

    @Test @MainActor
    func aCustomBarIsTheAppsOwnTreeMadeForEachField() throws {
        let form = Form()
        var made: [Marker] = []
        form.keyboardBar = .custom {
            let marker = Marker()
            made.append(marker)
            return marker
        }
        let view = view(of: form)

        #expect(made.count == 3)
        let first = try #require(bar(of: view.embeddedView(of: form.name.id)))
        #expect(made.contains { $0 === first.root })
        view.host.detach()
    }

    @Test @MainActor
    func theBarHasTheHeightOfItsTree() throws {
        let form = Form()
        form.keyboardBar = .navigation
        let view = view(of: form)

        let field = try #require(view.embeddedView(of: form.name.id) as? UITextField)
        let accessory = try #require(field.inputAccessoryView)
        accessory.setNeedsLayout()
        accessory.layoutIfNeeded()
        #expect(accessory.frame.height >= 44)
        view.host.detach()
    }
#endif
