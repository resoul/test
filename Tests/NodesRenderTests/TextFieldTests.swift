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

    @MainActor
    private final class SignIn: Node {
        let email = TextField(placeholder: "Email", content: .email)
        let password = SecureField(placeholder: "Password")

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                email
                password
            }
        }
    }

    @Test @MainActor
    func aSecureFieldIsAFieldThatHidesWhatIsTypedAndTheNextFieldReachesIt() {
        let form = SignIn()
        let host = NodeHost(root: form, size: LayoutSize(width: 320, height: 400))
        host.layoutIfNeeded()

        #expect(form.password.isSecure)
        #expect(!form.email.isSecure)
        #expect(form.password.content == .password)
        var asked: [String] = []
        form.password.onEditingRequest = { asked.append("password \($0)") }
        form.email.onEditingRequest = { asked.append("email \($0)") }
        var typed: [String] = []
        form.password.onChange = { typed.append($0) }

        // Next from the field before goes to it, and the text it holds is what was typed.
        form.email.returnKey = .next
        form.email.userSubmitted()
        form.password.userChanged("123456")
        #expect(asked == ["password true"])
        #expect(form.password.text == "123456")
        #expect(typed == ["123456"])
        host.detach()
    }

    @Test(
        arguments: [
            "a@b.co", "ada.lovelace+news@example.com", "x@sub.domain.example.org", "a@b-c.io",
            "Ada@Example.COM", "1@2.34",
        ]
    )
    func anAddressOfTheRightFormPasses(_ address: String) {
        #expect(EmailField.isWellFormed(address))
    }

    @Test(
        arguments: [
            "a", "a@", "@b.co", "a@b", "a b@c.de", "a@@b.co", "a@b@c.de", "a@b..co", "a@.co",
            "a@b.co.", "a@-b.co", "a@b-.co", "a@b_c.co", "a@b.co ", "",
        ]
    )
    func anAddressNotOfTheRightFormDoesNot(_ address: String) {
        #expect(!EmailField.isWellFormed(address))
    }

    @Test @MainActor
    func anEmailFieldChecksTheFormWhenTheUserLeavesItAndOnReturn() {
        let field = EmailField(placeholder: "Email")
        var seen: [FieldValidation] = []
        field.onValidationChange = { seen.append($0) }

        // Typing does not check yet; leaving does.
        field.userChanged("ada")
        #expect(field.validation == .unchecked)
        field.editingChanged(true)
        field.editingChanged(false)
        #expect(field.validation == .invalid(EmailField.defaultMessage))
        #expect(field.validationMessage == EmailField.defaultMessage)

        // Once checked, each change checks again: the message goes as soon as it is right.
        field.userChanged("ada@example.com")
        #expect(field.validation == .valid)
        #expect(field.validationMessage == nil)
        field.userChanged("ada@")
        #expect(field.validation == .invalid(EmailField.defaultMessage))
        // Only changes of the finding are told.
        #expect(
            seen == [
                .invalid(EmailField.defaultMessage), .valid, .invalid(EmailField.defaultMessage),
            ]
        )

        // An empty field has nothing to check, and Return checks.
        field.userChanged("")
        #expect(field.validation == .unchecked)
        field.userChanged("x")
        field.userSubmitted()
        #expect(field.validation == .invalid(EmailField.defaultMessage))
    }

    @Test @MainActor
    func theTimingSaysWhenAFieldChecksByItself() {
        let field = TextField(placeholder: "Name")
        field.validator = { $0.isEmpty ? .invalid("Enter your name") : .valid }

        field.validationTiming = .onInput
        field.userChanged("A")
        #expect(field.validation == .valid)
        field.userChanged("Ada")
        field.text = "Ada"
        // Text set by code was not checked, and what was found no longer stands.
        #expect(field.validation == .unchecked)

        field.validationTiming = .onSubmit
        field.editingChanged(false)
        #expect(field.validation == .unchecked)
        field.userSubmitted()
        #expect(field.validation == .valid)
        field.userChanged("")
        #expect(field.validation == .invalid("Enter your name"))
    }

    @Test @MainActor
    func validateChecksAtAnyTimeAndAFieldWithoutARuleChecksNothing() {
        let plain = TextField(placeholder: "Note")
        plain.userChanged("anything")
        #expect(plain.validate() == .unchecked)

        let email = EmailField("nobody", placeholder: "Email")
        #expect(email.validation == .unchecked)
        #expect(email.validate() == .invalid(EmailField.defaultMessage))
        // The app's own rule replaces the form check.
        email.validator = { _ in .valid }
        #expect(email.validate() == .valid)

        let custom = EmailField("bad", placeholder: "Email", message: "Not an address")
        #expect(custom.validate() == .invalid("Not an address"))
    }
#endif
