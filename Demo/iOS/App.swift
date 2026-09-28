// The demo screen on iPhone and iPad, and on the Mac through Mac Catalyst, in a stack of
// screens — a message opened in the inbox goes over it: the `LayoutDemoiOS` scheme of
// `Demo.xcodeproj`. The app is the layer's `Application`: one scene, the screen's menu on
// iPad's menu bar, links into the demo (`DemoModel.routes`).
import AppShell
import AppShellUIKit
import Foundation
import Nodes

@main
struct LayoutDemo: Application {
    private let model = DemoModel()

    var scenes: [WindowScene] {
        WindowScene("main", title: "Layout demo") { model.stack }
    }

    var menuBar: MenuBar {
        MenuBar { DemoModel.menu }
    }

    func started(_ shell: Shell) {
        model.askToDelete(from: ProcessInfo.processInfo.environment)
        model.openMessages(from: ProcessInfo.processInfo.environment)
        model.openCompose(from: ProcessInfo.processInfo.environment)
    }

    func open(_ request: OpenRequest) -> OpenResult {
        model.open(request.url) ? .opened : .unsupported
    }
}
