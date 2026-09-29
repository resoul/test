import AppShell
import LayoutCore
import Nodes
import NodesRender

/// A screen of `FIELDS_PROBE=1` for UI tests of text fields: a name, a password that shows
/// dots, and a line saying how long the password typed is — the model gets what the field
/// hides.
@MainActor
enum FieldsProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Fields")
    }

    private final class Page: Node {
        let name = TextField(placeholder: "Name", content: .name)
        let password = SecureField(placeholder: "Password")
        let phone = TextField(placeholder: "Phone", content: .phone)
        let length = Text("Password has 0 characters", style: TextStyle(size: 17))

        override init() {
            super.init()
            name.returnKey = .next
            password.returnKey = .next
            phone.returnKey = .done
            password.onChange = { [weak self] text in
                self?.length.text = "Password has \(text.count) characters"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                name
                password
                phone
                length
            }
            .gap(16)
            .padding(24)
        }
    }
}
