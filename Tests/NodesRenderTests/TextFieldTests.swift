#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    @MainActor
    private final class Form: Node {
        let name = TextField(placeholder: "Name")
        let email = TextField(placeholder: "Email", content: .email)

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                name
                email
            }
        }
    }

    @Test @MainActor
    func returnMovesToTheNextFieldAndTheUsersTextReachesTheModel() {
        let form = Form()
        let host = NodeHost(root: form, size: LayoutSize(width: 320, height: 400))
        host.layoutIfNeeded()
        var asked: [String] = []
        form.name.onEditingRequest = { asked.append("name \($0)") }
        form.email.onEditingRequest = { asked.append("email \($0)") }
        var changes: [String] = []
        form.name.onChange = { changes.append($0) }
        var submitted = 0
        form.name.onSubmit = { submitted += 1 }

        form.name.userChanged("Ada")
        form.name.userChanged("Ada")
        #expect(form.name.text == "Ada")
        #expect(changes == ["Ada"])
        // Set by code, the text shows without onChange.
        form.name.text = "Grace"
        #expect(changes == ["Ada"])

        form.name.returnKey = .next
        form.name.userSubmitted()
        #expect(submitted == 1)
        form.email.returnKey = .next
        form.email.userSubmitted()
        form.email.returnKey = .done
        form.email.userSubmitted()
        // The last field's Next, and Done, give the keyboard up.
        #expect(asked == ["email true", "email false", "email false"])
        host.detach()
    }
#endif
