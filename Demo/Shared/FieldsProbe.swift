import AppShell
import LayoutCore
import Nodes
import NodesRender

/// A screen of `FIELDS_PROBE=1` for UI tests of text fields: a name, an email checked when the
/// user leaves it (a line says what the check found), a password that shows dots, and a line
/// saying how long the password typed is — the model gets what the field hides.
@MainActor
enum FieldsProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Fields")
    }

    private final class Page: Node {
        let name = TextField(placeholder: "Name", content: .name)
        let email = EmailField(placeholder: "Email")
        let password = SecureField(placeholder: "Password")
        let phone = TextField(placeholder: "Phone", content: .phone)
        let length = Text("Password has 0 characters", style: TextStyle(size: 17))
        let emailStatus = Text("Email not checked", style: TextStyle(size: 17))

        override init() {
            super.init()
            name.returnKey = .next
            email.returnKey = .next
            password.returnKey = .next
            phone.returnKey = .done
            email.onValidationChange = { [weak self] validation in
                guard let self else { return }

                switch validation {
                case .unchecked: emailStatus.text = "Email not checked"
                case .valid: emailStatus.text = "Email is fine"
                case .invalid(let message): emailStatus.text = message
                }
            }
            password.onChange = { [weak self] text in
                self?.length.text = "Password has \(text.count) characters"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                name
                email
                password
                phone
                length
                emailStatus
            }
            .gap(16)
            .padding(24)
        }
    }
}
