// The demo screen on Apple TV: the remote moves the focus between the Follow badges and the
// Rename button, the select button presses the focused one, and Play/Pause brings the focus
// back to Ada's badge: the `LayoutDemoTV` scheme of `Demo.xcodeproj`, on an Apple TV
// simulator.
import AppShell
import AppShellUIKit
import LayoutUIKit
import Nodes
import NodesUIKit
import ThemeCore
import UIKit

@main
struct LayoutDemo: Application {
    private let model = DemoModel()

    /// The demo's stack, or a screen for UI tests: `ScreenController.probe` shows one of
    /// UIKit's, `STACK_PROBE` a stack of its own (`StackProbe`).
    var scenes: [WindowScene] {
        WindowScene("main", title: "Layout demo") {
            let environment = ProcessInfo.processInfo.environment
            if let probe = ScreenController.probe(environment) {
                return ControllerScreen(ScreenController(probe))
            }
            if environment["STACK_PROBE"] != nil {
                return StackProbe.makeStack()
            }
            return model.stack
        }
    }

    func started(_ shell: Shell) {
        // Play/Pause on the remote asks for the focus on Ada's badge, from wherever it is.
        let badge = model.firstBadge
        model.screen.handle(.playPause) { [weak badge] in
            guard let badge else { return }

            badge.host?.requestFocus(badge.id)
        }
        model.openMessages(from: ProcessInfo.processInfo.environment)
    }

    func open(_ request: OpenRequest) -> OpenResult {
        model.open(request.url) ? .opened : .unsupported
    }
}

/// Shows a screen for UI tests full size, with the margins a TV screen needs.
final class ScreenController: UIViewController {
    /// A screen for UI tests instead of the demo: the remote's reach (`FocusProbe`), moving
    /// rows with it (`MoveProbe`), or its buttons as commands (`CommandProbe`).
    static func probe(_ environment: [String: String]) -> Node? {
        environment["FOCUS_PROBE"].map { FocusProbe($0) }
            ?? environment["MOVE_PROBE"].map { _ in MoveProbe() }
            ?? environment["COMMAND_PROBE"].map { _ in CommandProbe() }
    }

    private let screen: NodeView

    init(_ root: Node) {
        screen = NodeView(root: root)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Palette.standard.background)
        // The screen is made for a phone; on a TV a node view shows it twice as big by
        // itself (`zoom`).
        screen.host.solvesInBackground = true
        screen.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(screen)
        let margins = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            screen.topAnchor.constraint(equalTo: margins.topAnchor),
            screen.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        [screen]
    }
}
