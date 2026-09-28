// The demo screen in a Mac window, in a stack of screens — a message opened in the inbox
// slides in over it — with the standard menus around the screen's commands: the
// `LayoutDemoMac` scheme of `Demo.xcodeproj`.
import AppShell
import AppShellAppKit
import Foundation
import Nodes

@main
struct LayoutDemo: Application {
    private let model = DemoModel()

    var scenes: [WindowScene] {
        WindowScene("main", title: "Layout demo") { model.stack }
    }

    var menuBar: MenuBar {
        MenuBar {
            DemoModel.menu
            Menu("Go") { Command.back }
        }
    }

    func started(_ shell: Shell) {
        model.openMessages(from: ProcessInfo.processInfo.environment)
    }

    func open(_ request: OpenRequest) -> OpenResult {
        model.open(request.url) ? .opened : .unsupported
    }
}
