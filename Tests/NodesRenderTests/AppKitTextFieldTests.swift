#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    @testable import NodesAppKit

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
    private func fieldViews(of fields: Fields) -> (NodeNSView, [String: NSTextField]) {
        let view = NodeNSView(root: fields)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        view.layout()
        view.layout()
        var byName: [String: NSTextField] = [:]
        for field in fields.all {
            if let text = view.embeddedView(of: field.id) as? NSTextField {
                byName[field.placeholder] = text
            }
        }
        return (view, byName)
    }

    @Test @MainActor
    func eachKindOfFieldGetsWhatTheSystemFillsItWith() throws {
        let fields = Fields()
        let (view, byName) = fieldViews(of: fields)
        #expect(byName.count == 8)

        #expect(byName["Text"]?.contentType == nil)
        #expect(byName["Name"]?.contentType == .name)
        #expect(byName["Email"]?.contentType == .emailAddress)
        #expect(byName["Password"]?.contentType == .password)
        #expect(byName["New password"]?.contentType == .newPassword)
        #expect(byName["Phone"]?.contentType == .telephoneNumber)
        #expect(byName["Code"]?.contentType == .oneTimeCode)
        #expect(byName["Web"]?.contentType == .URL)
        view.host.detach()
    }

    @Test @MainActor
    func onlyTheSecureFieldsHideWhatIsTyped() throws {
        let fields = Fields()
        let (view, byName) = fieldViews(of: fields)

        for (name, text) in byName {
            let secure = name == "Password" || name == "New password"
            #expect((text is NSSecureTextField) == secure, "\(name)")
        }
        view.host.detach()
    }
#endif
