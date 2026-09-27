// The demo screen on Apple TV: the remote moves the focus between the Follow badges and the
// Rename button, the select button presses the focused one, and Play/Pause brings the focus
// back to Ada's badge: the `LayoutDemoTV` scheme of `Demo.xcodeproj`, on an Apple TV
// simulator.
import LayoutUIKit
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

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ScreenController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Shows the node screen full size, with the margins a TV screen needs.
final class ScreenController: UIViewController {
    private let model = DemoModel()
    /// A screen for the remote's reach instead of the demo, for UI tests (`FocusProbe`).
    private let probe = ProcessInfo.processInfo.environment["FOCUS_PROBE"].map { FocusProbe($0) }
    private lazy var screen = NodeView(root: probe ?? model.screen)

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

    /// Play/Pause on the remote asks for the focus on Ada's badge, from wherever it is.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .playPause }) {
            screen.host.requestFocus(model.firstBadge.id)
        } else {
            super.pressesBegan(presses, with: event)
        }
    }
}
