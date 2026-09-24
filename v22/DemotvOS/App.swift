// The demo screen on Apple TV: the remote moves the focus between the Follow badges and the
// Rename button, and the select button presses the focused one. Open `DemotvOS.xcodeproj`
// in Xcode and run it on an Apple TV simulator.
import DemoScreens
import NodesUIKit
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
    private lazy var screen = NodeView(root: model.screen)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
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
