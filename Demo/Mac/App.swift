// The demo screen in a Mac window, in a stack of screens — a message opened in the inbox
// slides in over it — with the standard menus around the screen's commands: the
// `LayoutDemoMac` scheme of `Demo.xcodeproj`.
import AppShell
import AppKit
import AppShellAppKit
import Foundation
import Nodes
import NodesAppKit

@main
struct LayoutDemo: Application {
    private let model = DemoModel()

    var scenes: [WindowScene] {
        // Several windows are a probe of their own: each makes its content anew.
        if let probe = WindowsProbe.scenes(ProcessInfo.processInfo.environment) { return probe }

        return [
            WindowScene("main", title: "Layout demo") {
                ContainerProbe.content(ProcessInfo.processInfo.environment) ?? model.stack
            }
        ]
    }

    /// The demo puts its state back only when asked (`RESTORATION_PROBE`): the UI tests of the
    /// rest start from a clean screen.
    var restoresState: Bool {
        ProcessInfo.processInfo.environment["RESTORATION_PROBE"] != nil
    }

    var menuBar: MenuBar {
        MenuBar {
            DemoModel.menu
            Menu("Go") { Command.back }
        }
    }

    func started(_ shell: Shell) {
        // The rich text editor's formats, before the Window menu: they go to the editor while it
        // has the keyboard and are disabled elsewhere.
        if let main = NSApplication.shared.mainMenu {
            let format = NSMenuItem(title: "Text Format", action: nil, keyEquivalent: "")
            format.submenu = .richTextFormat
            main.insertItem(format, at: max(main.numberOfItems - 1, 0))
        }
        if ProcessInfo.processInfo.environment["TOAST_PROBE"] != nil {
            ToastProbe.install(on: shell)
        }
        model.askToDelete(from: ProcessInfo.processInfo.environment)
        model.openMessages(from: ProcessInfo.processInfo.environment)
        model.openCompose(from: ProcessInfo.processInfo.environment)
        model.openForm(from: ProcessInfo.processInfo.environment)
    }

    func open(_ request: OpenRequest) -> OpenResult {
        model.open(request.url) ? .opened : .unsupported
    }
}
