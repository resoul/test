#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Fields: Node {
        let all: [TextField] = [
            TextField(placeholder: "Text"),
            TextField(placeholder: "Name", content: .name),
            TextField(placeholder: "Email", content: .email),
            SecureField(placeholder: "Password"),
            SecureField(placeholder: "New password", content: .newPassword),
            TextField(placeholder: "Phone", content: .phone),
            TextField(placeholder: "Code", content: .oneTimeCode),
            TextField(placeholder: "Web", content: .url),
        ]

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for field in all { field }
            }
        }
    }

    @MainActor
    private func fieldViews(of fields: Fields) -> (NodeView, [String: UITextField]) {
        let view = NodeView(root: fields)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        view.layoutIfNeeded()
        var byName: [String: UITextField] = [:]
        for field in fields.all {
            if let text = view.embeddedView(of: field.id) as? UITextField {
                byName[field.placeholder] = text
            }
        }
        return (view, byName)
    }

    @Test @MainActor
    func eachKindOfFieldGetsItsKeyboardAndWhatTheSystemFillsItWith() throws {
        let fields = Fields()
        let (view, byName) = fieldViews(of: fields)
        #expect(byName.count == 8)

        #expect(byName["Text"]?.textContentType == nil)
        #expect(byName["Name"]?.textContentType == .name)
        #expect(byName["Email"]?.keyboardType == .emailAddress)
        #expect(byName["Email"]?.autocapitalizationType == UITextAutocapitalizationType.none)
        #expect(byName["Password"]?.textContentType == .password)
        #expect(byName["Password"]?.autocorrectionType == .no)
        #expect(byName["New password"]?.textContentType == .newPassword)
        #expect(byName["Phone"]?.keyboardType == .phonePad)
        #expect(byName["Phone"]?.textContentType == .telephoneNumber)
        #expect(byName["Code"]?.keyboardType == .numberPad)
        #expect(byName["Code"]?.textContentType == .oneTimeCode)
        #expect(byName["Web"]?.keyboardType == .URL)
        #expect(byName["Web"]?.textContentType == .URL)
        view.host.detach()
    }

    @Test @MainActor
    func onlyTheSecureFieldsHideWhatIsTyped() throws {
        let fields = Fields()
        let (view, byName) = fieldViews(of: fields)

        for (name, text) in byName {
            let secure = name == "Password" || name == "New password"
            #expect(text.isSecureTextEntry == secure, "\(name)")
        }
        view.host.detach()
    }
#endif
