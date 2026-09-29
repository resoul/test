import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender

/// `TOAST_PROBE=1` for UI tests of toasts: a button that shows "Message deleted" with an Undo
/// action over the window — through the app's command, as an app would — and a line counting
/// how many times Undo was taken.
@MainActor
enum ToastProbe {
    static let showToast = Command("showToast", title: "Show toast")
    static let showLongToast = Command("showLongToast", title: "Show long toast")

    private static let undone = Undone()

    /// Counts what the toasts' actions did, and tells the page.
    private final class Undone {
        var count = 0
        var changed: (@MainActor () -> Void)?
    }

    static func content() -> any SceneContent {
        NodeScreen(Page(undone: undone), title: "Toast")
    }

    /// The app's part: the commands that show the toasts.
    static func install(on shell: Shell) {
        shell.handle(showToast) {
            shell.toast(
                Toast(
                    "Message deleted",
                    action: ToastAction("Undo") {
                        undone.count += 1
                        undone.changed?()
                    },
                    duration: 3
                )
            )
        }
        shell.handle(showLongToast) {
            shell.toast(Toast("Could not save", persistent: true))
        }
        // `TOAST_AUTO` shows one as the app starts, to look at without touching anything.
        if let auto = ProcessInfo.processInfo.environment["TOAST_AUTO"] {
            shell.perform(auto == "long" ? showLongToast : showToast)
        }
    }

    private final class Page: Node {
        let show = Button(command: ToastProbe.showToast)
        let showLong = Button(command: ToastProbe.showLongToast)
        let status = Text("Undone 0 times", style: TextStyle(size: 17))

        init(undone: Undone) {
            super.init()
            undone.changed = { [weak self] in
                self?.status.text = "Undone \(undone.count) times"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                show
                showLong
                status
            }
            .gap(16)
            .padding(24)
            .alignItems(.start)
        }
    }
}
