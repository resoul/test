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

    init() {
        // Background transfers need their session at launch, before any scene: the system may have
        // results to deliver the moment the app runs.
        BackgroundProbe.start(ProcessInfo.processInfo.environment)
    }

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
        MenuBar { DemoModel.menu }
    }

    func started(_ shell: Shell) {
        if ProcessInfo.processInfo.environment["TOAST_PROBE"] != nil {
            ToastProbe.install(on: shell)
        }
        BackgroundProbe.install(on: shell)
        model.askToDelete(from: ProcessInfo.processInfo.environment)
        model.openMessages(from: ProcessInfo.processInfo.environment)
        model.openCompose(from: ProcessInfo.processInfo.environment)
        model.openForm(from: ProcessInfo.processInfo.environment)
    }

    func open(_ request: OpenRequest) -> OpenResult {
        model.open(request.url) ? .opened : .unsupported
    }
}
