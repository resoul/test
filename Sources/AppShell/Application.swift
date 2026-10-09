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

    /// The kinds of scene the app has; the first standard one opens when it starts. Asked when a
    /// scene opens: each scene makes its content anew.
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

    /// Whether the app keeps the state of its scenes across launches and puts it back
    /// (`SceneSession.restorationData()`). The default is `true`; the containers that opted in
    /// (`Stack.restorable(using:allowing:)`) are what is kept.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var restoresState: Bool { get }

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

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var restoresState: Bool { true }

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

/// What a presentation shows: a `Stack`, a `Screen`, or an `Alert`.
///
/// Ownership: the presentation keeps its content. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public protocol PresentationContent: CommandResponder {}

extension Stack: PresentationContent {}
extension Screen: PresentationContent {}

/// A kind of scene of an app — a window on the Mac and iPad, the screen on iPhone and Apple TV
/// — as a scene configuration: its id, its title, and how its content is made, anew for each
/// session of the kind. Not `Scene`: that is SwiftUI's.
///
/// Ownership: keeps the closure making the content. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public struct WindowScene {
    /// What a kind of scene is for.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Role: Hashable, Sendable {
        /// A scene of the app's own content: the first of these opens at launch, and a new one
        /// opens on request (`Shell.openScene`, Command-N) where the platform takes more than one.
        case standard
        /// The app's settings window, Command-comma on a Mac: one at most, never at launch,
        /// opened from the app's menu; where the platform keeps settings elsewhere (iPad, iPhone,
        /// Apple TV) it does not open.
        case settings
    }

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let id: String

    /// The scene's title where the platform shows one, until its content gives its own.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let title: String

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let role: Role

    /// Whether the app can have more than one scene of this kind at a time. A request for
    /// another brings the one there forward. Never for the settings window.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let allowsMultiple: Bool

    let makeContent: @MainActor () -> any SceneContent

    /// Ownership: keeps `content`, which must make new content each time. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public init(
        _ id: String,
        title: String = "",
        role: Role = .standard,
        allowsMultiple: Bool = true,
        content: @escaping @MainActor () -> any SceneContent
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.allowsMultiple = allowsMultiple && role == .standard
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

/// What became of a request for a scene (`Shell.openScene`).
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SceneOpenResult: Hashable, Sendable {
    /// The platform was asked for a new scene: on a Mac its window is there at once, on iPad
    /// the system connects it a moment later, and its session joins `Shell.sessions` then.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case opened
    /// The kind takes one scene at a time and has one: it is brought forward.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case activated
    /// The app has no such kind, or the platform does not take another scene of it — iPhone
    /// and Apple TV have one screen, an iPad app takes more only when its `Info.plist` says so.
    /// Nothing changed; the app shows what it means to in place.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case unsupported
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

    // The toast over the window: what shows, and the timer that takes it away.
    let toastState = State<ShownToast?>(nil)
    var toastTimer: Task<Void, Never>?
    var toastDeadline: Date?
    var toastRemaining: Double?

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

    /// What brings the platform's scene forward, and back if the system let go of its views.
    package var activatePlatformScene: (@MainActor () -> Void)?

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

    /// Brings the scene forward: its window becomes the key one on a Mac, the scene comes to the
    /// front on iPad.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func activate() {
        activatePlatformScene?()
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

extension Command {
    /// A new window of the app's first standard kind of scene: Command-N. Enabled where the
    /// platform takes another scene (`Shell.openScene`).
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let newWindow = Command(
        "newWindow",
        title: "New Window",
        shortcut: Shortcut("n", [.command])
    )

    /// The app's settings window: Command-comma. Enabled where the app has a scene of the
    /// settings role and the platform opens it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let openSettings = Command(
        "openSettings",
        title: "Settings…",
        shortcut: Shortcut(",", [.command])
    )
}

/// What the platform gives the shell to open scenes.
package struct PlatformScenes {
    /// Whether the platform takes a new scene of the kind now.
    package var canOpen: @MainActor (WindowScene) -> Bool
    /// Asks the platform for a new scene of the kind.
    package var open: @MainActor (WindowScene) -> Void

    package init(
        canOpen: @escaping @MainActor (WindowScene) -> Bool,
        open: @escaping @MainActor (WindowScene) -> Void
    ) {
        self.canOpen = canOpen
        self.open = open
    }
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

    /// How the platform opens scenes; the adapter sets it.
    package var platformScenes: PlatformScenes?

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

    /// The app's ``activation`` now, and then each time it changes, as a sequence.
    ///
    /// This is for code that is not on the main actor or wants to wait for the app to come and go —
    /// keeping a socket open only while the app shows, for instance, by passing
    /// `shell.activations().map { $0 != .background }` to a web socket client's `follow`. A
    /// change that leaves the answer the same, such as one scene going inactive while another is
    /// still active, is not repeated. If the consumer is slower than the app, it gets the latest
    /// value and misses the ones in between.
    ///
    /// The sequence does not keep the shell alive, and ends when the shell goes. Stopping the
    /// iteration, or dropping the sequence, stops the observation.
    public func activations() -> AsyncStream<SceneActivation> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SceneActivation.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        var last: SceneActivation?
        let effect = Effect { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }

            let current = activation
            if current != last {
                last = current
                continuation.yield(current)
            }
        }
        continuation.onTermination = { _ in
            Task { @MainActor in effect.cancel() }
        }
        return stream
    }

    /// What the app does when the system starts it, or wakes it, to deliver the results of transfers that
    /// went on without it: it gets the identifier of the background `URLSession` they belong to and a
    /// completion to call once the app has taken in the results.
    ///
    /// The app makes its background transfers object for that identifier (or already has) and passes the
    /// completion to it, which calls it when the events are delivered; for a session that is not the app's, call
    /// the completion at once. A call that came before the handler was set waits for it, and is made
    /// when it is set. Only apps on iPhone, iPad and Apple TV are told; a Mac app is started by the
    /// system without a call.
    public var backgroundSessionHandler:
        (@MainActor (_ identifier: String, _ completion: @escaping @MainActor () -> Void) -> Void)?
    {
        didSet {
            guard let backgroundSessionHandler else { return }

            let waiting = pendingBackgroundSessions
            pendingBackgroundSessions = []
            for (identifier, completion) in waiting {
                backgroundSessionHandler(identifier, completion)
            }
        }
    }
    private var pendingBackgroundSessions: [(String, @MainActor () -> Void)] = []

    /// For platform adapters: the system has events for the background session `identifier`.
    package func backgroundSessionEvents(
        identifier: String,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let backgroundSessionHandler else {
            pendingBackgroundSessions.append((identifier, completion))
            return
        }

        backgroundSessionHandler(identifier, completion)
    }

    /// For platform adapters: the running `application`.
    package init(application: any Application) {
        self.application = application
        super.init()
        handle(
            .newWindow,
            isEnabled: { [weak self] in self?.canOpenScene(self?.launchKind) ?? false }
        ) { [weak self] in
            self?.openScene()
        }
        handle(
            .openSettings,
            isEnabled: { [weak self] in self?.canOpenScene(self?.settingsKind) ?? false }
        ) { [weak self] in
            guard let id = self?.settingsKind?.id else { return }

            self?.openScene(id)
        }
    }

    /// The kind that opens at launch and for a new window: the first standard one.
    private var launchKind: WindowScene? {
        application.scenes.first { $0.role == .standard }
    }

    private var settingsKind: WindowScene? {
        application.scenes.first { $0.role == .settings }
    }

    private func canOpenScene(_ kind: WindowScene?) -> Bool {
        guard let kind, let platformScenes else { return false }

        return platformScenes.canOpen(kind)
    }

    /// Opens a new scene of the kind `id` — the one that opens at launch when `nil` — where the
    /// platform takes another: a window on a Mac, a scene on iPad when the app says it takes
    /// more than one. A kind that takes one at a time and has one brings it forward instead.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: the result says what became of it.
    /// Cancellation: not applicable.
    @discardableResult
    public func openScene(_ id: String? = nil) -> SceneOpenResult {
        let kinds = application.scenes
        guard let kind = id.map({ id in kinds.first { $0.id == id } }) ?? launchKind,
            let platformScenes, platformScenes.canOpen(kind)
        else { return .unsupported }

        if !kind.allowsMultiple, let existing = sessions.first(where: { $0.kind.id == kind.id }) {
            existing.activate()
            return .activated
        }

        platformScenes.open(kind)
        return .opened
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

    /// Makes a session of the scene kind `id` — the one that opens at launch when `nil` — with
    /// new content, in the chain of commands: content, session, app. `nil` when the app has no
    /// such kind.
    package func makeSession(_ id: String? = nil) -> SceneSession? {
        let kinds = application.scenes
        guard let kind = id.map({ id in kinds.first { $0.id == id } }) ?? launchKind else {
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
        session.dismissToast()
        (session.content as? any ClosableContent)?.closeContent()
        session.content.outer = nil
        session.outer = nil
    }
}
