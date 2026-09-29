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
            // A scene the app asked for (`Shell.openScene`) carries its kind in the activity of
            // the request; it goes into the scene session, where the scene's delegate reads it,
            // and where it stays for the scene's life.
            if let kind = options.userActivities.lazy.compactMap({
                $0.userInfo?[ShellSceneDelegate.kindKey] as? String
            }).first {
                connectingSceneSession.userInfo = [ShellSceneDelegate.kindKey: kind]
            }
            let configuration = UISceneConfiguration(
                name: nil,
                sessionRole: connectingSceneSession.role
            )
            configuration.delegateClass = ShellSceneDelegate.self
            return configuration
        }

        /// Gives the shell what it needs to open scenes: an iPad app that takes more than one
        /// (`UIApplicationSupportsMultipleScenes`) can, apart from the settings window, which is
        /// a Mac's.
        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
        ) -> Bool {
            Self.shell?.platformScenes = PlatformScenes(
                canOpen: { kind in
                    kind.role == .standard && UIApplication.shared.supportsMultipleScenes
                },
                open: { kind in
                    let activity = NSUserActivity(activityType: ShellSceneDelegate.openType)
                    activity.addUserInfoEntries(from: [ShellSceneDelegate.kindKey: kind.id])
                    UIApplication.shared.requestSceneSessionActivation(
                        nil,
                        userActivity: activity,
                        options: nil,
                        errorHandler: nil
                    )
                }
            )
            return true
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

        /// Where the kind of a scene is kept in its scene session, and in the activity that asks
        /// for a new one.
        static let kindKey = "sceneKind"

        /// The type of the activity that asks the system for a new scene.
        static let openType = "openScene"

        /// The activity that carries the scene's snapshot (`SceneSession.restorationData()`)
        /// across launches, and where in it the data is.
        private static let restorationType = "restoration"
        private static let restorationKey = "snapshot"

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
            // The system may have let go of the scene's views: asking for its session brings it
            // forward, and connects it again if it is not there.
            session.activatePlatformScene = { [weak platform] in
                guard let platform else { return }

                UIApplication.shared.requestSceneSessionActivation(
                    platform,
                    userActivity: nil,
                    options: nil,
                    errorHandler: nil
                )
            }

            // What the last run kept is put back before the screens are made, so that the first
            // thing shown is where the user was; a link that came since is handled after.
            if shell.application.restoresState,
                let data = platform.stateRestorationActivity?.userInfo?[Self.restorationKey]
                    as? Data
            {
                session.restore(from: data)
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

        /// The system asks for the scene's state when the app goes to the background.
        func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
            guard ShellApplicationDelegate.shell?.application.restoresState == true,
                let data = session?.restorationData()
            else { return nil }

            let activity = NSUserActivity(activityType: Self.restorationType)
            activity.addUserInfoEntries(from: [Self.restorationKey: data])
            return activity
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
