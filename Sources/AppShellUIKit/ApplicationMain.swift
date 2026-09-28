#if canImport(UIKit)
    import AppShell
    import Nodes
    import NodesUIKit
    import UIKit

    extension Application {
        /// The entry point of an app on iPhone, iPad and Apple TV: `@main` on the type calls
        /// it. Each scene of the app is a `UIWindowScene`: the first kind opens at launch; the
        /// system connects, disconnects and discards them. The app's `Info.plist` asks for
        /// scenes (`UIApplicationSceneManifest`) and says whether it takes more than one.
        ///
        /// Ownership: the app runs until the system ends it. Isolation: MainActor. Errors:
        /// none. Cancellation: not applicable.
        public static func main() {
            ShellApplicationDelegate.shell = Shell(application: Self())
            _ = UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(ShellApplicationDelegate.self)
            )
        }
    }

    /// The app's delegate: the configuration of each scene, the sessions the system
    /// discards, and the menus on iPad.
    @MainActor
    final class ShellApplicationDelegate: UIResponder, UIApplicationDelegate {
        /// The running app, set before UIKit starts.
        static var shell: Shell?

        /// The session of each scene the system has, by the scene session's identifier: it
        /// outlives the scene's views, which the system may let go of and connect again.
        static var sessions: [String: SceneSession] = [:]

        func application(
            _ application: UIApplication,
            configurationForConnecting connectingSceneSession: UISceneSession,
            options: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            let configuration = UISceneConfiguration(
                name: nil,
                sessionRole: connectingSceneSession.role
            )
            configuration.delegateClass = ShellSceneDelegate.self
            return configuration
        }

        /// The user closed scenes for good — in the app switcher, with Close Window: their
        /// sessions go, with their content.
        func application(
            _ application: UIApplication,
            didDiscardSceneSessions sceneSessions: Set<UISceneSession>
        ) {
            for platform in sceneSessions {
                guard let session = Self.sessions.removeValue(forKey: platform.persistentIdentifier)
                else { continue }

                Self.shell?.sessionClosed(session)
            }
        }

        /// The app's menus go after View on iPad's menu bar.
        @available(tvOS, unavailable)
        override func buildMenu(with builder: any UIMenuBuilder) {
            super.buildMenu(with: builder)
            guard builder.system == .main, let shell = Self.shell else { return }

            var after = UIMenu.Identifier.view
            for menu in shell.application.menuBar.menus {
                let element = UIMenu(menu)
                builder.insertSibling(element, afterMenu: after)
                after = element.identifier
            }
        }
    }

    /// A scene's delegate: its window with the session's content, its activation, its links.
    @MainActor
    final class ShellSceneDelegate: UIResponder, UIWindowSceneDelegate {
        var window: UIWindow?
        private var session: SceneSession?

        /// Where the kind of a scene is kept in its scene session.
        private static let kindKey = "sceneKind"

        func scene(
            _ scene: UIScene,
            willConnectTo platform: UISceneSession,
            options connectionOptions: UIScene.ConnectionOptions
        ) {
            guard let scene = scene as? UIWindowScene, let shell = ShellApplicationDelegate.shell
            else { return }

            let key = platform.persistentIdentifier
            let kind = platform.userInfo?[ShellSceneDelegate.kindKey] as? String
            guard
                let session = ShellApplicationDelegate.sessions[key]
                    ?? shell.makeSession(kind)
            else { return }

            ShellApplicationDelegate.sessions[key] = session
            platform.userInfo = [ShellSceneDelegate.kindKey: session.kind.id]
            self.session = session
            session.canClose = UIApplication.shared.supportsMultipleScenes
            session.closePlatformScene = { [weak platform] in
                guard let platform else { return }

                UIApplication.shared.requestSceneSessionDestruction(
                    platform,
                    options: nil,
                    errorHandler: nil
                )
            }

            let window = UIWindow(windowScene: scene)
            window.rootViewController = contentController(for: session.content)
            if scene.title?.isEmpty ?? true {
                scene.title = session.kind.title
            }
            window.makeKeyAndVisible()
            self.window = window

            shell.firstSceneShown()
            for context in connectionOptions.urlContexts {
                shell.open(context.url, in: session)
            }
        }

        func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
            for context in contexts {
                ShellApplicationDelegate.shell?.open(context.url, in: session)
            }
        }

        func sceneDidBecomeActive(_ scene: UIScene) {
            session?.setActivation(.active)
        }

        func sceneWillResignActive(_ scene: UIScene) {
            session?.setActivation(.inactive)
        }

        func sceneWillEnterForeground(_ scene: UIScene) {
            session?.setActivation(.inactive)
        }

        func sceneDidEnterBackground(_ scene: UIScene) {
            session?.setActivation(.background)
        }

        /// The system let go of the scene's views: the window goes, the session stays with its
        /// content — the system may connect the scene again — until it is discarded.
        func sceneDidDisconnect(_ scene: UIScene) {
            session?.setActivation(.background)
            window = nil
            session = nil
        }
    }
#endif
