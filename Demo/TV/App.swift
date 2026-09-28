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
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// The demo, while it shows.
    private var model: DemoModel?
    /// The stack a UI test drives (`StackProbe`), while it shows.
    private var probeStack: Stack<StackProbe.Route>?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let environment = ProcessInfo.processInfo.environment
        if let probe = ScreenController.probe(environment) {
            window.rootViewController = ScreenController(probe)
        } else if environment["STACK_PROBE"] != nil {
            let stack = StackProbe.makeStack()
            probeStack = stack
            window.rootViewController = stack.makeViewController()
        } else {
            let model = DemoModel()
            // Play/Pause on the remote asks for the focus on Ada's badge, from wherever it is.
            let badge = model.firstBadge
            model.screen.handle(.playPause) { [weak badge] in
                guard let badge else { return }

                badge.host?.requestFocus(badge.id)
            }
            model.openMessages(from: environment)
            self.model = model
            window.rootViewController = model.stack.makeViewController()
        }
        window.makeKeyAndVisible()
        self.window = window
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
