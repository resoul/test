import AppShell
import Foundation
import Nodes
import NodesRender

/// Scenes for UI tests of several windows, chosen by `WINDOWS_PROBE=1`: a notes window whose
/// stack goes to the next note with a button — each window has its own path, and it is kept
/// across launches — and a settings window of the settings role.
@MainActor
enum WindowsProbe {
    static func scenes(_ environment: [String: String]) -> [WindowScene]? {
        guard environment["WINDOWS_PROBE"] != nil else { return nil }

        return [
            WindowScene("notes", title: "Notes") { notes() },
            WindowScene("settings", title: "Settings", role: .settings) {
                NodeScreen(ContainerProbe.Page("Settings screen"), title: "Settings")
            },
        ]
    }

    private enum NoteRoute: Hashable, Sendable {
        case note(Int)
    }

    private static let noteRoutes = RouteTable<NoteRoute> {
        RoutePattern(
            "/notes/:number",
            route: { .note(try $0.value("number")) },
            values: { route in
                guard case .note(let number) = route else { return nil }

                return ["number": String(number)]
            }
        )
    }

    private static func notes() -> Stack<NoteRoute> {
        weak var stack: Stack<NoteRoute>?
        let made = Stack(root: NoteRoute.note(1)) { route in
            guard case .note(let number) = route else { return NodeScreen(Node()) }

            return NodeScreen(
                ContainerProbe.Page(
                    "Note \(number)",
                    buttons: [Button("Next note") { stack?.push(.note(number + 1)) }]
                ),
                title: "Note \(number)"
            )
        }
        stack = made
        made.restorable(using: noteRoutes)
        return made
    }
}
