#if canImport(UIKit)
    import UIKit

    @main @MainActor
    final class ComparisonApp: UIResponder, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            configurationForConnecting session: UISceneSession,
            options: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            let configuration = UISceneConfiguration(name: "Comparison", sessionRole: session.role)
            configuration.delegateClass = ComparisonScene.self
            return configuration
        }
    }

    @MainActor
    final class ComparisonScene: UIResponder, UIWindowSceneDelegate {
        var window: UIWindow?
        func scene(
            _ scene: UIScene,
            willConnectTo session: UISceneSession,
            options connectionOptions: UIScene.ConnectionOptions
        ) {
            guard let scene = scene as? UIWindowScene else { return }
            let session = ComparisonSession()
            let native = NativeFeedController(session: session)
            let nodes = NodeFeedController(session: session)
            native.tabBarItem = UITabBarItem(
                title: "UIKit",
                image: UIImage(systemName: "list.bullet.rectangle"),
                tag: 0
            )
            nodes.tabBarItem = UITabBarItem(
                title: "Nodes",
                image: UIImage(systemName: "square.stack.3d.up"),
                tag: 1
            )
            let tabs = UITabBarController()
            let controllers = [native, nodes].map { controller in
                let navigation = UINavigationController(rootViewController: controller)
                navigation.tabBarItem = controller.tabBarItem
                return navigation
            }
            tabs.viewControllers = controllers
            tabs.view.tintColor = FeedStyle.ui(FeedStyle.accent)
            let tabStyle = UITabBarAppearance()
            tabStyle.configureWithOpaqueBackground()
            tabStyle.backgroundColor = FeedStyle.ui(FeedStyle.background)
            tabs.tabBar.standardAppearance = tabStyle
            tabs.tabBar.scrollEdgeAppearance = tabStyle
            if ProcessInfo.processInfo.environment["COMPARISON_ENGINE"] == "nodes" {
                tabs.selectedIndex = 1
            }
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = tabs
            self.window = window
            window.makeKeyAndVisible()
        }
    }

    @MainActor
    class FeedController: UIViewController {
        let session: ComparisonSession
        init(session: ComparisonSession) {
            self.session = session
            super.init(nibName: nil, bundle: nil)
            session.observers.append { [weak self] in self?.contentChanged() }
        }
        required init?(coder: NSCoder) { fatalError("Use init(session:)") }

        override func viewDidLoad() {
            super.viewDidLoad()
            navigationItem.title = "Полевые заметки"
            view.backgroundColor = FeedStyle.ui(FeedStyle.background)
            navigationController?.navigationBar.tintColor = FeedStyle.ui(FeedStyle.accent)
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = FeedStyle.ui(FeedStyle.background)
            appearance.shadowColor = .clear
            navigationItem.standardAppearance = appearance
            navigationItem.scrollEdgeAppearance = appearance
            updateMenu()
        }

        func contentChanged() { if isViewLoaded { updateMenu() } }
        private func updateMenu() {
            let count = session.count
            let options = [100, 500, 2000].map { value in
                UIAction(title: "\(value) записей", state: value == count ? .on : .off) {
                    [weak self] _ in
                    self?.session.reload(count: value)
                }
            }
            let reset = UIAction(
                title: "Начать сначала",
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in
                self?.session.reload()
            }
            let button = UIBarButtonItem(
                title: "\(count)",
                menu: UIMenu(children: options + [reset])
            )
            button.accessibilityIdentifier = "feed-options"
            button.accessibilityLabel = "Количество записей"
            navigationItem.rightBarButtonItem = button
        }
    }
#endif
