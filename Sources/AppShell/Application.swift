import Foundation
import Nodes
import StateCore

/// An app made of the layer's scenes, screens and stacks, from one entry point on iPhone,
/// iPad, Apple TV and the Mac:
///
///     @main
///     struct MailApp: Application {
///         let store = MailStore()
///
///         var scenes: [WindowScene] {
///             WindowScene("main", title: "Mail") { store.stack }
///         }
///
///         var menuBar: MenuBar {
///             MenuBar { Menu("Message") { Command.flag; Command.archive } }
///         }
///
///         func open(_ request: OpenRequest) -> OpenResult {
///             guard let path = try? routes.path(for: request.url) else { return .unsupported }
///             store.stack.setPath(path)
///             return .opened
///         }
///     }
///
/// The adapter the app imports — `AppShellUIKit` or `AppShellAppKit` — gives the entry point
/// (`main()`), shows each scene in the platform's own — a `UIWindowScene`, an `NSWindow` —
/// puts up the menus, and brings links in. The app's `Info.plist` stays the app's: its URL
/// types, whether it takes more than one scene.
///
/// Ownership: the running app (`Shell`) keeps the instance for as long as it runs.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public protocol Application {
    /// Makes the app when it starts, once.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    init()

    /// The kinds of scene the app has; the first one opens when it starts. Asked when a scene
    /// opens: each scene makes its content anew.
    ///
    /// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @SceneBuilder var scenes: [WindowScene] { get }

    /// The app's menus: on a Mac between the standard ones (the app's, File, Edit) and
    /// Window, on iPad after View. The default is none.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var menuBar: MenuBar { get }

    /// The app started and its first scene shows: the place for the app's own commands
    /// (`shell.handle(.newMessage) { ... }`), which come after every scene's. The default
    /// does nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func started(_ shell: Shell)

    /// A link to open — from another app, a notification, a universal link, the app itself
    /// (`Shell.open`). Links that came before the first scene showed come once it does, in
    /// the order they came. The default opens nothing.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: the result says what became of it.
    /// Cancellation: not applicable.
    func open(_ request: OpenRequest) -> OpenResult
}

extension Application {
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var menuBar: MenuBar { MenuBar {} }

    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func started(_ shell: Shell) {}

    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func open(_ request: OpenRequest) -> OpenResult { .unsupported }
}

/// What a scene shows: a `Stack`, or a single `Screen`.
///
/// Ownership: the scene's session keeps its content. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public protocol SceneContent: CommandResponder {}

extension Stack: SceneContent {}
extension Screen: SceneContent {}

/// A kind of scene of an app — a window on the Mac and iPad, the screen on iPhone and Apple TV
/// — as a scene configuration: its id, its title, and how its content is made, anew for each
/// session of the kind. Not `Scene`: that is SwiftUI's.
///
/// Ownership: keeps the closure making the content. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public struct WindowScene {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let id: String

    /// The scene's title where the platform shows one, until its content gives its own.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let title: String

    let makeContent: @MainActor () -> any SceneContent

    /// Ownership: keeps `content`, which must make new content each time. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public init(
        _ id: String,
        title: String = "",
        content: @escaping @MainActor () -> any SceneContent
    ) {
        self.id = id
        self.title = title
        makeContent = content
    }
}

/// Builds the scenes of an `Application`.
///
/// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
@resultBuilder
public enum SceneBuilder {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildExpression(_ scene: WindowScene) -> [WindowScene] {
        [scene]
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildBlock(_ parts: [WindowScene]...) -> [WindowScene] {
        parts.flatMap { $0 }
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildOptional(_ part: [WindowScene]?) -> [WindowScene] {
        part ?? []
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildEither(first part: [WindowScene]) -> [WindowScene] {
        part
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func buildEither(second part: [WindowScene]) -> [WindowScene] {
        part
    }
}

/// How much a scene is in use, as `UIScene.ActivationState`.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SceneActivation: Hashable, Sendable {
    /// Shown and taking input: the key window on a Mac, the active scene elsewhere.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case active
    /// Shown, without input: another window is key, the notification center is over it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case inactive
    /// Not shown: minimized, hidden, the app in the background.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case background
}

/// A link for the app to open, and the scene it came to, if one.
///
/// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public struct OpenRequest {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let url: URL

    /// The scene the platform brought the link to — a scene on iPad, a window on the Mac —
    /// else the first one; the app picks another if it wants.
    ///
    /// Ownership: the shell keeps the session. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public let session: SceneSession?

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init(url: URL, session: SceneSession? = nil) {
        self.url = url
        self.session = session
    }
}

/// What became of a link.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum OpenResult: Hashable, Sendable {
    /// The app took it: its screens show when their moves end.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case opened
    /// It waits for the first scene to show, and goes to the app then.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case queued
    /// The app has nothing for it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case unsupported
    /// Too many links wait for the first scene: this one is turned down, the ones before
    /// it stay.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case queueFull
}

/// A scene of the running app, as `UISceneSession`: its content, its activation, and the
/// commands of a window — closing it. It lasts while the scene exists, across the platform
/// letting go of its views and connecting them again: the content and its stack's path stay.
/// Its content's commands come to it, and go on to the app.
///
/// Ownership: the shell keeps the session until the scene is closed for good; the session
/// keeps its content. Isolation: MainActor. Errors: none. Cancellation: `close()`.
@MainActor
public final class SceneSession: CommandResponder {
    /// The id of this session, apart from others of its kind.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let id = UUID()

    /// The kind of scene it is.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let kind: WindowScene

    /// What the scene shows: a `Stack` or a `Screen`, as its kind made it.
    ///
    /// Ownership: kept by the session. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let content: any SceneContent

    private let activationState = State(SceneActivation.background)

    /// How much the scene is in use; `.background` while it does not show. Reading it under
    /// tracking depends on it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var activation: SceneActivation { activationState.value }

    /// Whether the platform can close the scene: on a Mac, and on iPad taking more than one
    /// scene. The adapter sets it.
    package var canClose = false

    /// What closes the platform's scene; it reports back with `Shell.sessionClosed`.
    package var closePlatformScene: (@MainActor () -> Void)?

    init(kind: WindowScene, content: any SceneContent) {
        self.kind = kind
        self.content = content
        super.init()
        handle(.closeWindow, isEnabled: { [weak self] in self?.canClose ?? false }) {
            [weak self] in
            self?.close()
        }
    }

    /// Asks the platform to close the scene, where it can — a window on the Mac, a scene on
    /// iPad; the shell lets go of the session once the platform did.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func close() {
        guard canClose else { return }

        closePlatformScene?()
    }

    /// For platform adapters: the platform's scene changed its activation.
    package func setActivation(_ activation: SceneActivation) {
        activationState.value = activation
    }
}

extension Command {
    /// Closing the window — the scene: Command-W.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let closeWindow = Command(
        "closeWindow",
        title: "Close Window",
        shortcut: Shortcut("w", [.command])
    )
}

/// The running app: its scenes, its activation, its links, and the commands no scene carries
/// out — the app's own (`Application.started`).
///
/// Ownership: the adapter keeps it for as long as the app runs; it keeps the app and the
/// sessions of its scenes. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public final class Shell: CommandResponder {
    /// Ownership: kept by the shell. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let application: any Application

    private let sessionsState = State<[SceneSession]>([])
    private var pending: [OpenRequest] = []
    private var isReady = false

    /// How many links wait at most for the first window.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var linkQueueLimit = 16

    /// The sessions of the app's scenes, in the order they opened. Reading it under tracking
    /// depends on it.
    ///
    /// Ownership: returns the sessions the shell keeps. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var sessions: [SceneSession] { sessionsState.value }

    /// The app's activation: active while a scene is, else inactive while one shows, else
    /// background. Reading it under tracking depends on every scene's.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var activation: SceneActivation {
        let activations = sessions.map(\.activation)
        if activations.contains(.active) { return .active }
        if activations.contains(.inactive) { return .inactive }
        return .background
    }

    /// For platform adapters: the running `application`.
    package init(application: any Application) {
        self.application = application
        super.init()
    }

    /// Opens `url` in the app — in `session`, else the app picks: at once when its first
    /// scene shows, else when it does.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: the result says what became of it.
    /// Cancellation: not applicable.
    @discardableResult
    public func open(_ url: URL, in session: SceneSession? = nil) -> OpenResult {
        guard isReady else {
            guard pending.count < linkQueueLimit else { return .queueFull }

            pending.append(OpenRequest(url: url, session: session))
            return .queued
        }

        return application.open(OpenRequest(url: url, session: session ?? sessions.first))
    }

    // MARK: - For platform adapters

    /// Makes a session of the scene kind `id` — the first kind when `nil` — with new content,
    /// in the chain of commands: content, session, app. `nil` when the app has no such kind.
    package func makeSession(_ id: String? = nil) -> SceneSession? {
        let kinds = application.scenes
        guard let kind = id.map({ id in kinds.first { $0.id == id } }) ?? kinds.first else {
            return nil
        }

        let session = SceneSession(kind: kind, content: kind.makeContent())
        session.content.outer = session
        session.outer = self
        sessionsState.value.append(session)
        return session
    }

    /// The first scene shows: the app is told it started, and the links that waited go to it
    /// in the order they came.
    package func firstSceneShown() {
        guard !isReady else { return }

        isReady = true
        application.started(self)
        let waiting = pending
        pending = []
        for request in waiting {
            _ = application.open(
                OpenRequest(url: request.url, session: request.session ?? sessions.first)
            )
        }
    }

    /// The platform closed the scene of `session` for good: the shell lets go of it, and a
    /// stack in it of its screens.
    package func sessionClosed(_ session: SceneSession) {
        sessionsState.value.removeAll { $0 === session }
        (session.content as? any PresentedStack)?.close()
        (session.content as? Screen)?.presentation?.dismiss()
        session.content.outer = nil
        session.outer = nil
    }
}
