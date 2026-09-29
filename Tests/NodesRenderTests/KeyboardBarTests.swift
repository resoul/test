#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import Testing

    @testable import NodesRender

    @MainActor
    private final class Form: Node {
        let name = TextField(placeholder: "Name")
        let notes = TextEditor(placeholder: "Notes")
        let email = TextField(placeholder: "Email", content: .email)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                name
                notes
                email
            }
        }
    }

    @MainActor
    private func mounted(_ form: Form) -> NodeHost {
        let host = NodeHost(root: form, size: LayoutSize(width: 320, height: 600))
        host.layoutIfNeeded()
        return host
    }

    @Test @MainActor
    func theKeyboardMovesBetweenFieldsAndEditorsInTheOrderTheTreeIsRead() {
        let form = Form()
        let host = mounted(form)

        #expect(form.name.neighbor(1) === form.notes)
        #expect(form.notes.neighbor(1) === form.email)
        #expect(form.email.neighbor(1) == nil)
        #expect(form.email.neighbor(-1) === form.notes)
        #expect(form.name.neighbor(-1) == nil)
        #expect(form.name.neighbor(2) === form.email)
        host.detach()
    }

    @Test @MainActor
    func returnWithNextGoesOnToAnEditorToo() {
        let form = Form()
        let host = mounted(form)
        var asked: [String] = []
        form.notes.onEditingRequest = { asked.append("notes \($0)") }
        form.name.returnKey = .next

        form.name.userSubmitted()
        #expect(asked == ["notes true"])
        host.detach()
    }

    @Test @MainActor
    func theNavigationBarTurnsOffWhatLeadsNowhereAndItsButtonsMoveTheKeyboard() {
        let form = Form()
        let host = mounted(form)
        var asked: [String] = []
        form.name.onEditingRequest = { asked.append("name \($0)") }
        form.notes.onEditingRequest = { asked.append("notes \($0)") }
        form.email.onEditingRequest = { asked.append("email \($0)") }

        let first = KeyboardNavigationBar(input: form.name)
        #expect(!first.previous.isEnabled)
        #expect(first.next.isEnabled)
        let middle = KeyboardNavigationBar(input: form.notes)
        #expect(middle.previous.isEnabled && middle.next.isEnabled)
        let last = KeyboardNavigationBar(input: form.email)
        #expect(last.previous.isEnabled)
        #expect(!last.next.isEnabled)

        middle.next.onTap?()
        middle.previous.onTap?()
        middle.done.onTap?()
        #expect(asked == ["email true", "name true", "notes false"])
        #expect(middle.previous.accessibility.label == "Previous field")
        #expect(middle.next.accessibility.label == "Next field")
        #expect(middle.done.accessibility.label == "Done")
        host.detach()
    }

    @Test @MainActor
    func aBarSetOnANodeIsEveryFieldUnderItsAndAFieldMaySetItsOwn() {
        let form = Form()
        let host = mounted(form)

        func kind(_ bar: KeyboardBar) -> String {
            switch bar {
            case .none: "none"
            case .navigation: "navigation"
            case .custom: "custom"
            }
        }
        #expect(kind(form.name.effectiveKeyboardBar) == "none")

        form.keyboardBar = .navigation
        #expect(kind(form.name.effectiveKeyboardBar) == "navigation")
        #expect(kind(form.email.effectiveKeyboardBar) == "navigation")

        form.email.keyboardBar = KeyboardBar.none
        #expect(kind(form.email.effectiveKeyboardBar) == "none")
        form.notes.keyboardBar = .custom { Node() }
        #expect(kind(form.notes.effectiveKeyboardBar) == "custom")
        #expect(kind(form.name.effectiveKeyboardBar) == "navigation")
        host.detach()
    }
#endif
