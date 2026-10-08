#if canImport(UIKit)
    import UIKit

    import TrellisCore
    import TrellisRender

    /// Native boundary of a Trellis tree on iOS, iPadOS, and tvOS.
    ///
    /// The view owns its bridge and forwards only its own window's bounds, scale, safe area,
    /// direction, and scene activity. Layout, layer ownership, and tree callbacks stay in
    /// `TrellisRender`.
    ///
    /// Ownership: retains its bridge; the bridge retains the mounted root and renderer.
    /// Isolation: MainActor. Errors: a root already owned by another host is not attached.
    /// Cancellation: `detach()` and removal from a window suspend or cancel bridge work.
    @MainActor
    public final class TrellisHostView: UIView {
        private var bridge: NodeHostBridge?
        private var proxies: NativeProxyCoordinator?
        private var focusChangeHandler: (@MainActor (FocusChange) -> Void)?

        /// Draws every committed node's frame and `NodeID` over the rendered tree (C25). A
        /// view-level setting: it survives `attach`/`detach` and is applied to whichever bridge
        /// is current. Never affects layout or triggers a render.
        ///
        /// Ownership: the view stores the flag; the bridge owns the overlay layers. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var isDebugOverlayEnabled = false {
            didSet { bridge?.isDebugOverlayEnabled = isDebugOverlayEnabled }
        }

        /// What the overlay's labels show (defect #11): runtime `NodeID`s, or tree-order
        /// positions that do not change with nodes created elsewhere — the Playground's
        /// screenshot export uses the latter. A view-level setting like the overlay itself.
        ///
        /// Ownership: the view stores the value; the bridge applies it. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public var debugOverlayLabelStyle: DebugOverlayLabelStyle = .runtimeID {
            didSet { bridge?.debugOverlayLabelStyle = debugOverlayLabelStyle }
        }
        private weak var observedScene: UIScene?

        /// Scale factor of the screen that currently contains the host.
        ///
        /// Before being attached to a window the screen is unknown, so the value is `1`:
        /// layout is not triggered at this point anyway because the host size is zero.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var hostScale: Double { hostScaleOverride ?? Double(window?.screen.scale ?? 1) }

        /// Pins the pixel scale the tree is laid out and rendered at, instead of following the
        /// window's screen. For reproducible evidence — the Playground's screenshot export
        /// sets 2 so a reference rendered on a Retina display compares byte-for-byte on a 1×
        /// external one (defect #17). `nil` (default) follows the screen again.
        ///
        /// Ownership: the view stores the value. Isolation: MainActor. Errors: a non-finite
        /// or non-positive value is ignored. Cancellation: not applicable.
        public var hostScaleOverride: Double? {
            didSet {
                if let hostScaleOverride, !(hostScaleOverride.isFinite && hostScaleOverride > 0) {
                    self.hostScaleOverride = nil
                    return
                }
                bridge?.updateBounds(currentBounds, scale: hostScale)
            }
        }

        /// Creates an empty host without starting work.
        ///
        /// Ownership: the caller owns the view. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            installTouchObserver()
        }

        /// Creates a host from an unarchiver.
        ///
        /// Ownership: UIKit owns the decoded view. Isolation: MainActor.
        /// Errors: decoding follows the UIKit contract. Cancellation: not applicable.
        public required init?(coder: NSCoder) {
            super.init(coder: coder)
            isOpaque = false
            installTouchObserver()
        }

        /// R08/defect #75: `touches{Began,Moved,Ended,Cancelled}` below only fire when this
        /// view itself wins `hitTest(_:with:)` — a `ScrollNode` embeds a real `UIScrollView` as
        /// a *subview* of this host (`UIScrollViewBacking.init`), so any touch landing inside it
        /// hit-tests to that subview instead, and this view's own touch overrides never run for
        /// it. `TrellisTouchObserver` is a `UIGestureRecognizer` attached directly to this view:
        /// UIKit delivers touch events to every gesture recognizer attached along a touch's
        /// hit-tested view's superview chain regardless of which subview was actually hit — the
        /// documented mechanism a container uses to observe touches happening on its own
        /// subviews. It forwards every phase into this view's own handlers below, which are
        /// already the correct, tested logic — the observer duplicates nothing, it just makes
        /// them reachable for touches a subview intercepted. `cancelsTouchesInView = false`
        /// leaves native subview behavior (the `UIScrollView`'s own pan/momentum,
        /// `TransitionGestureController`'s pan, an overlay `UIButton`) completely unaffected.
        private func installTouchObserver() {
            addGestureRecognizer(TrellisTouchObserver(host: self))
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        /// Attaches `root` using one consistent initial host state.
        ///
        /// Ownership: the bridge retains `root` until replacement or `detach`. Isolation:
        /// MainActor. Errors: an already-mounted root is rejected and this view becomes detached.
        /// Cancellation: replacing a root detaches the previous bridge and cancels its work.
        public func attach(root: Node) {
            detach()
            let bridge = ensureBridge()
            guard
                bridge.attach(
                    root: root,
                    bounds: currentBounds,
                    scale: hostScale,
                    safeAreaInsets: currentSafeAreaInsets,
                    layoutDirection: currentLayoutDirection,
                    textRenderer: CoreTextRenderer(),
                    localeIdentifier: currentLocaleIdentifier,
                    reduceMotion: currentReduceMotion,
                    scrollBackingFactory: { [weak self] nodeID, delegate in
                        UIScrollViewBacking(
                            nodeID: nodeID,
                            delegate: delegate,
                            superview: self ?? UIView()
                        )
                    }
                )
            else { return }

            bridge.isDebugOverlayEnabled = isDebugOverlayEnabled
            bridge.debugOverlayLabelStyle = debugOverlayLabelStyle
            installSceneObservers()
            setNeedsLayout()
        }

        /// Binds a `StateSubject` to a node-updating closure for the life of this view (C29):
        /// delivery follows `attach`/`detach` and scene activity, see
        /// `NodeHostBridge.bindState(_:update:)`. Bindings outlive any one attached root, so the
        /// same view can show a fresh root with the current state after a detach/attach.
        ///
        /// Ownership: the view's bridge retains the binding until `cancel()`. Isolation:
        /// MainActor. Errors: none. Cancellation: `StateBinding.cancel()`.
        @discardableResult
        public func bindState<Value: Sendable & Equatable>(
            _ subject: StateSubject<Value>,
            update: @escaping @MainActor (Value) -> Void
        ) -> StateBinding {
            ensureBridge().bindState(subject, update: update)
        }

        /// This view's underlying bridge, creating it if needed — an escape hatch for API
        /// this view does not itself forward (e.g. `TrellisFlux`'s `bindFlux`, R05), without
        /// this module depending on whatever added it. Always non-`nil` here (a `UIView`
        /// always has a `layer`); `Optional` only to match `TrellisAppKit`'s same-named
        /// property, so cross-platform Playground-style code can write `host.hostBridge?...`
        /// once.
        ///
        /// Ownership: the view retains its bridge; a caller must not retain it past this
        /// view's own lifetime. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var hostBridge: NodeHostBridge? { ensureBridge() }

        /// The node with keyboard/remote focus in this host, or `nil` (A08, D39).
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var focusedID: NodeID? { bridge?.focusedID }

        /// Called once per completed focus transition in this host (D39). Survives
        /// `attach`/`detach`.
        ///
        /// Ownership: the view retains the closure; it must not retain this view strongly.
        /// Isolation: MainActor. Errors: none. Cancellation: assign `nil`.
        public var onFocusChange: (@MainActor (FocusChange) -> Void)? {
            get { focusChangeHandler }
            set { focusChangeHandler = newValue }
        }

        /// Requests focus on a node, or clears it — see `NodeHostBridge.focus`. On tvOS the
        /// engine's transition is confirmed by the platform focus system (D44).
        ///
        /// Ownership: nothing is retained. Isolation: MainActor. Errors: `.unavailable` without
        /// a mounted, committed tree. Cancellation: not applicable.
        @discardableResult
        public func focus(_ id: NodeID?) -> FocusMoveResult { bridge?.focus(id) ?? .unavailable }

        /// Moves focus in a direction — see `NodeHostBridge.moveFocus`.
        ///
        /// Ownership: nothing is retained. Isolation: MainActor. Errors: `.unavailable` without
        /// a mounted, committed tree. Cancellation: not applicable.
        @discardableResult
        public func moveFocus(_ direction: FocusDirection) -> FocusMoveResult {
            bridge?.moveFocus(direction) ?? .unavailable
        }

        /// The modal focus/accessibility scope, or `nil` (A05, D40).
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var focusScopeID: NodeID? { bridge?.focusScopeID }

        /// Opens or closes the modal focus/accessibility scope — see
        /// `NodeHostBridge.setFocusScope`.
        ///
        /// Ownership: identities only. Isolation: MainActor. Errors: an unknown id is ignored.
        /// Cancellation: not applicable.
        public func setFocusScope(_ id: NodeID?) { bridge?.setFocusScope(id) }

        /// Performs an accessibility action on a published element — see
        /// `NodeHostBridge.performAccessibilityAction`.
        ///
        /// Ownership: nothing is retained. Isolation: MainActor. Errors: `false` when refused.
        /// Cancellation: not applicable.
        @discardableResult
        public func performAccessibilityAction(_ action: AccessibilityAction, on id: NodeID) -> Bool
        {
            bridge?.performAccessibilityAction(action, on: id) ?? false
        }

        /// The committed raster bitmap for `id`, if one exists and nothing has superseded it
        /// since — see `NodeHostBridge.displayArtifact(for:)`. `nil` before attaching. T12: a
        /// caller that needs to know a scene is fully rendered (not just laid out) before
        /// capturing it — a fixed delay after the geometry commit is not a bound on when
        /// CoreText rasterization (a separate, asynchronous step, D53) actually finishes.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public func displayArtifact(for id: NodeID) -> DisplayArtifact? {
            bridge?.displayArtifact(for: id)
        }

        /// A synchronous snapshot of scene readiness (M07, D69) — see
        /// `NodeHostBridge.sceneReadiness`. `nil` before attaching.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var sceneReadiness: NodeHostBridge.SceneReadiness? { bridge?.sceneReadiness }

        /// Polls scene readiness until every axis is satisfied or `timeout` elapses — see
        /// `NodeHostBridge.waitUntilSceneReady(timeout:)`. Throws
        /// `NodeHostBridge.SceneReadinessError.timeout` (also thrown when nothing is attached).
        ///
        /// Ownership: touches no external state. Isolation: MainActor. Errors:
        /// `NodeHostBridge.SceneReadinessError.timeout`. Cancellation: cooperative.
        public func waitUntilSceneReady(
            timeout: Duration = .seconds(2)
        ) async throws -> NodeHostBridge.SceneReadiness {
            guard let bridge else { throw NodeHostBridge.SceneReadinessError.timeout }
            return try await bridge.waitUntilSceneReady(timeout: timeout)
        }

        /// The active composite `.expand` session, or `nil` — see `NodeHostBridge.
        /// transitionSession` (D70–D74, M11–M13). `nil` before attaching.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var transitionSession: TransitionSession? { bridge?.transitionSession }

        /// Opens, or retargets, a composite `.expand` transition — see
        /// `NodeHostBridge.presentTransition(_:)`.
        ///
        /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false`
        /// without a mounted, committed tree, or for every rejection `NodeHostBridge.
        /// presentTransition(_:)` documents. Cancellation: as the bridge method.
        @discardableResult
        public func presentTransition(_ request: NodeHostBridge.TransitionRequest) -> Bool {
            bridge?.presentTransition(request) ?? false
        }

        /// Closes the active `.expand` session by button (non-interactive) — see
        /// `NodeHostBridge.closeTransition()`.
        ///
        /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false`
        /// without a mounted tree or a `.presented` session. Cancellation: as the bridge method.
        @discardableResult
        public func closeTransition() -> Bool { bridge?.closeTransition() ?? false }

        /// Begins live gesture control of the active `.expand` session — see
        /// `NodeHostBridge.beginTransitionGesture()`. The entry point `TransitionGestureController`
        /// (this module) calls; also usable directly by a host that drives its own recognizer.
        ///
        /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false`
        /// without a mounted tree, or for every rejection the bridge method documents.
        /// Cancellation: as the bridge method.
        @discardableResult
        public func beginTransitionGesture() -> Bool { bridge?.beginTransitionGesture() ?? false }

        /// Moves the live `.expand` gesture's progress — see
        /// `NodeHostBridge.updateTransitionGesture(deltaProgress:)`.
        ///
        /// Ownership: touches only the active session's already-armed layers. Isolation:
        /// MainActor. Errors: none — a no-op without a mounted tree or outside
        /// `.interactiveClosing`. Cancellation: not applicable.
        public func updateTransitionGesture(deltaProgress: Double) {
            bridge?.updateTransitionGesture(deltaProgress: deltaProgress)
        }

        /// Ends the live `.expand` gesture — see
        /// `NodeHostBridge.endTransitionGesture(velocity:preset:)`.
        ///
        /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false`
        /// without a mounted tree or outside `.interactiveClosing`. Cancellation: as the bridge
        /// method.
        @discardableResult
        public func endTransitionGesture(
            velocity: Double,
            preset: TransitionGesturePreset? = nil
        ) -> Bool {
            bridge?.endTransitionGesture(velocity: velocity, preset: preset) ?? false
        }

        /// Resolves a system-interrupted `.expand` gesture — see
        /// `NodeHostBridge.cancelTransitionGestureSystemInterrupted()`.
        ///
        /// Ownership: retains nothing past the call. Isolation: MainActor. Errors: `false`
        /// without a mounted tree or outside `.interactiveClosing`. Cancellation: this call is
        /// one.
        @discardableResult
        public func cancelTransitionGestureSystemInterrupted() -> Bool {
            bridge?.cancelTransitionGestureSystemInterrupted() ?? false
        }

        /// Number of native focus/accessibility proxies currently alive for this host — an
        /// A12 ownership hook; bounded by the published snapshot, never by the number of
        /// commits.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var nativeProxyCount: Int { proxies?.proxyCount ?? 0 }

        /// Proxies created over this host's lifetime (A12): a steady tree must not grow it
        /// with commits.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var createdNativeProxyTotal: Int { proxies?.createdProxyTotal ?? 0 }

        /// The proxy registry — a test hook for the A08/A09 handshake, never a render path.
        var proxyCoordinatorForTesting: NativeProxyCoordinator? { proxies }

        /// One bridge for the view's lifetime, so bindings survive `detach`.
        private func ensureBridge() -> NodeHostBridge {
            if let bridge { return bridge }
            installLocaleObserver()
            installReduceMotionObserver()
            let bridge = NodeHostBridge(hostLayer: layer)
            self.bridge = bridge
            let coordinator = NativeProxyCoordinator(host: self, bridge: bridge)
            coordinator.isNativeFocusEnabled = traitCollection.userInterfaceIdiom == .tv
            proxies = coordinator
            bridge.onSemanticsPublished = { [weak self, weak bridge] snapshot in
                guard let self, let bridge else { return }

                self.proxies?.apply(
                    snapshot: snapshot,
                    tree: bridge.accessibilityTree,
                    scope: bridge.focusScopeID
                )
            }
            bridge.onFocusChange = { [weak self] change in
                guard let self else { return }

                self.proxies?.engineFocusChanged(change)
                self.focusChangeHandler?(change)
            }
            bridge.onAccessibilityTreeChanged = { [weak self] tree in
                self?.announceAccessibilityTree(tree)
            }
            return bridge
        }

        private var lastAnnouncedScope: NodeID?
        private var lastAnnouncedEpoch: UInt64?

        /// Tells VoiceOver the published tree changed (A09, D47) — after the proxies already
        /// show the new state. A scope change is a screen change (the background went away or
        /// came back); anything else is a layout change addressed to the focused proxy, so
        /// the cursor stays where it is. Not posted for an equal tree — the bridge never
        /// reports one.
        private func announceAccessibilityTree(_ tree: AccessibilityTree) {
            let scopeChanged =
                tree.scope != lastAnnouncedScope || tree.mountEpoch != lastAnnouncedEpoch
            lastAnnouncedScope = tree.scope
            lastAnnouncedEpoch = tree.mountEpoch
            let focused = focusedID.flatMap { proxies?.proxy(for: $0) }
            let notification: UIAccessibility.Notification =
                scopeChanged ? .screenChanged : .layoutChanged
            accessibilityNotificationSink?(notification, focused?.identity)
            UIAccessibility.post(notification: notification, argument: focused)
        }

        /// Observes the notifications this host posts — a test hook; `UIAccessibility.post`
        /// itself is not observable from a unit test.
        var accessibilityNotificationSink: ((UIAccessibility.Notification, NodeID?) -> Void)?

        /// The host is a container, never an element: VoiceOver lands on the proxies.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override var isAccessibilityElement: Bool {
            get { false }
            set {}
        }

        /// The published top-level elements in reading order, as native proxies (A09, D42) —
        /// confined to the modal scope when one is open (D40).
        ///
        /// Ownership: the proxies stay owned by this view. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override var accessibilityElements: [Any]? {
            get { proxies?.accessibilityRoots ?? [] }
            set {}
        }

        /// Detaches the current root and releases all bridge-owned work and layers. The bridge
        /// itself, and the state bindings it holds, stay for the next `attach`.
        ///
        /// Ownership: releases the retained root; keeps the bridge. Isolation: MainActor.
        /// Errors: none. Cancellation: cancels active layout work and pauses state delivery.
        public func detach() {
            removeSceneObservers()
            bridge?.detach()
            proxies?.removeAll()
        }

        /// Sends the current bounds and scale after UIKit has laid out this view.
        ///
        /// Ownership: borrows bridge state. Isolation: MainActor. Errors: none. Cancellation:
        /// newer bounds supersede pending layout work.
        public override func layoutSubviews() {
            super.layoutSubviews()
            bridge?.updateBounds(currentBounds, scale: hostScale)
        }

        /// Sends safe-area changes without waiting for an unrelated resize.
        ///
        /// Ownership: copies insets into the bridge. Isolation: MainActor. Errors: none.
        /// Cancellation: the pending layout pass is coalesced.
        public override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            bridge?.updateSafeArea(currentSafeAreaInsets)
        }

        /// Captures display scale and inherited direction changes even if bounds are unchanged.
        ///
        /// Ownership: borrows bridge state. Isolation: MainActor. Errors: none. Cancellation:
        /// latest host state supersedes earlier work.
        public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?)
        {
            super.traitCollectionDidChange(previousTraitCollection)
            updateBridgeState()
        }

        /// Rebinds lifecycle observation to the particular scene containing this host.
        ///
        /// Ownership: borrows the current scene and retains no observer token. Isolation:
        /// MainActor. Errors: none. Cancellation: leaving a window suspends bridge work.
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            removeSceneObservers()
            guard window != nil else {
                bridge?.suspend()
                proxies?.cancelPendingRequest()
                // UIKit does not guarantee `touchesCancelled` for a touch whose responder
                // leaves the hierarchy outright (unlike backgrounding, which does): drop this
                // adapter's own bookkeeping so a touch's eventual terminal call, if it ever
                // arrives, finds no id to act on instead of resurrecting a stale one.
                touchPointerIDs.removeAll()
                return
            }

            installSceneObservers()
            updateBridgeState()
            bridge?.resume()
            proxies?.isNativeFocusEnabled = isTV
            becomeFirstResponder()
        }

        private var currentBounds: LayoutFrame {
            LayoutFrame(width: Double(bounds.width), height: Double(bounds.height))
        }

        private var currentLayoutDirection: LayoutDirection {
            effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }

        /// The identifier `TextRendererKey`'s sibling `LocaleKey` receives at `attach` and
        /// whenever the system locale changes (T09) — `Locale.current` is a live snapshot, not
        /// itself observable, hence `localeDidChange` re-reading it on
        /// `NSLocale.currentLocaleDidChangeNotification`.
        private var currentLocaleIdentifier: String { Locale.current.identifier }

        /// The value `updateReduceMotion` receives at `attach` and whenever the system setting
        /// changes (D67) — `UIAccessibility.isReduceMotionEnabled` is a live snapshot, not
        /// itself observable, hence `reduceMotionDidChange` re-reading it on
        /// `UIAccessibility.reduceMotionStatusDidChangeNotification`.
        private var currentReduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

        private var currentSafeAreaInsets: DirectionalEdgeInsets {
            let direction = currentLayoutDirection
            return DirectionalEdgeInsets(
                top: Double(safeAreaInsets.top),
                leading: direction == .leftToRight
                    ? Double(safeAreaInsets.left) : Double(safeAreaInsets.right),
                bottom: Double(safeAreaInsets.bottom),
                trailing: direction == .leftToRight
                    ? Double(safeAreaInsets.right) : Double(safeAreaInsets.left)
            )
        }

        private func updateBridgeState() {
            bridge?.updateSafeArea(currentSafeAreaInsets)
            bridge?.updateLayoutDirection(currentLayoutDirection)
            bridge?.updateLocaleIdentifier(currentLocaleIdentifier)
            bridge?.updateReduceMotion(currentReduceMotion)
            bridge?.updateBounds(currentBounds, scale: hostScale)
        }

        private func installSceneObservers() {
            guard let scene = window?.windowScene else { return }
            observedScene = scene
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(sceneDidActivate(_:)),
                name: UIScene.didActivateNotification,
                object: scene
            )
            center.addObserver(
                self,
                selector: #selector(sceneWillDeactivate(_:)),
                name: UIScene.willDeactivateNotification,
                object: scene
            )
        }

        private func removeSceneObservers() {
            guard let observedScene else { return }
            let center = NotificationCenter.default
            center.removeObserver(
                self,
                name: UIScene.didActivateNotification,
                object: observedScene
            )
            center.removeObserver(
                self,
                name: UIScene.willDeactivateNotification,
                object: observedScene
            )
            self.observedScene = nil
        }

        @objc private func sceneDidActivate(_: Notification) {
            updateBridgeState()
            bridge?.resume()
        }

        @objc private func sceneWillDeactivate(_: Notification) { bridge?.suspend() }

        /// Registered once per view (from `ensureBridge`, guarded by the bridge itself already
        /// being created only once) rather than per-scene like `installSceneObservers` — a
        /// locale change is a system-wide event, not scoped to this host's window/scene.
        /// `deinit`'s `NotificationCenter.default.removeObserver(self)` already covers this
        /// registration too, so no separate teardown is needed (T09).
        private func installLocaleObserver() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(localeDidChange),
                name: NSLocale.currentLocaleDidChangeNotification,
                object: nil
            )
        }

        @objc private func localeDidChange() {
            bridge?.updateLocaleIdentifier(currentLocaleIdentifier)
        }

        /// Registered once per view (from `ensureBridge`, like `installLocaleObserver`) rather
        /// than per-scene — Reduce Motion is a system-wide accessibility setting, not scoped to
        /// this host's window/scene (D67). `deinit`'s `NotificationCenter.default.removeObserver`
        /// already covers this registration too — unlike AppKit's `accessibilityDisplayOptionsDid
        /// ChangeNotification`, `UIAccessibility`'s notifications post on the default center.
        private func installReduceMotionObserver() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reduceMotionDidChange),
                name: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil
            )
        }

        @objc private func reduceMotionDidChange() {
            bridge?.updateReduceMotion(currentReduceMotion)
        }

        /// The host itself is never the focused item; its proxies are (D44).
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override var canBecomeFocused: Bool { false }

        /// On tvOS, the committed focus candidates as native focus items (A08, D44) — one
        /// `TrellisNodeProxy` each, no `UIView` — merged with UIKit's own subview items. On
        /// iOS/iPadOS nothing is added: keyboard traversal there is the engine's alone (D38),
        /// so the platform focus system never becomes a second owner.
        ///
        /// Ownership: the returned proxies stay owned by this view. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public override func focusItems(in rect: CGRect) -> [any UIFocusItem] {
            super.focusItems(in: rect) + (proxies?.focusItems(in: rect) ?? [])
        }

        /// The proxy the engine wants focused — its pending request, else its current focus —
        /// so a programmatic transition is honoured by the platform on the next focus update
        /// and confirmed back through `didUpdateFocus` (D44).
        ///
        /// Ownership: the returned proxy stays owned by this view. Isolation: MainActor.
        /// Errors: none. Cancellation: not applicable.
        public override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            proxies?.preferredFocusEnvironments ?? []
        }

        /// Key and remote presses arrive at the first responder; the host claims that role so
        /// Select, Return, Space and (off tvOS) Tab/arrows reach the engine.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override var canBecomeFirstResponder: Bool { true }

        /// Routes a press to the focus engine (A08, D38/D43). Keyboard Tab/arrows move focus
        /// where the engine owns traversal (iOS/iPadOS); on tvOS the arrows belong to the
        /// platform focus system and are left to `super`. Return/Space/Select press the focused
        /// control. Anything the engine does not consume — Menu, Play/Pause, unmapped keys, a
        /// boundary Tab — continues up the responder chain.
        ///
        /// Ownership: borrows `presses`/`event`. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let unhandled = presses.filter { press in
                receive(.keyDown, press: press) == .unhandled
            }
            if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
        }

        /// Completes the press cycle a `pressesBegan` opened — activation happens here (D43).
        ///
        /// Ownership: borrows `presses`/`event`. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let unhandled = presses.filter { press in
                receive(.keyUp, press: press) == .unhandled
            }
            if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
        }

        /// A cancelled press never activates: the open cycle is closed without a key-up.
        ///
        /// Ownership: borrows `presses`/`event`. Isolation: MainActor. Errors: none.
        /// Cancellation: this is one.
        public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?)
        {
            if presses.contains(where: {
                Self.keyData(pressType: $0.type, key: $0.key, isTV: isTV) != nil
            }) {
                bridge?.cancelKeyPress()
            }
            super.pressesCancelled(presses, with: event)
        }

        private var isTV: Bool { traitCollection.userInterfaceIdiom == .tv }

        /// The press → engine step, with the `UIPress` already taken apart so tests can drive
        /// it without constructing one (UIKit offers no initializer).
        func receive(_ type: EventType, press: UIPress) -> KeyOutcome {
            receive(type, pressType: press.type, key: press.key)
        }

        func receive(_ type: EventType, pressType: UIPress.PressType, key: UIKey?) -> KeyOutcome {
            if isTV, type == .keyDown,
                let data = Self.keyData(pressType: pressType, key: key, isTV: false)
            {
                let direction: FocusDirection?
                switch data.key {
                case .upArrow: direction = .up
                case .downArrow: direction = .down
                case .leftArrow: direction = .left
                case .rightArrow: direction = .right
                default: direction = nil
                }
                if let direction, proxies?.revealFocus(direction) == true { return .handled }
            }
            guard let data = Self.keyData(pressType: pressType, key: key, isTV: isTV) else {
                return .unhandled
            }

            return bridge?.send(type, key: data) ?? .unhandled
        }

        /// `UIPress` → `KeyData`. Remote press types map directly; a keyboard press maps by HID
        /// usage. On tvOS the arrows are the platform's (D44) and Tab does not exist; Select
        /// is `.select`, Return/Space on a paired keyboard are keyboard keys.
        static func keyData(pressType: UIPress.PressType, key: UIKey?, isTV: Bool) -> KeyData? {
            if let key {
                let mapped: KeyboardKey?
                switch key.keyCode {
                case .keyboardTab: mapped = isTV ? nil : .tab
                case .keyboardUpArrow: mapped = isTV ? nil : .upArrow
                case .keyboardDownArrow: mapped = isTV ? nil : .downArrow
                case .keyboardLeftArrow: mapped = isTV ? nil : .leftArrow
                case .keyboardRightArrow: mapped = isTV ? nil : .rightArrow
                case .keyboardReturnOrEnter, .keypadEnter: mapped = .returnKey
                case .keyboardSpacebar: mapped = .space
                default: mapped = nil
                }
                if let mapped {
                    return KeyData(key: mapped, isShiftDown: key.modifierFlags.contains(.shift))
                }
            }
            switch pressType {
            case .select: return KeyData(key: .select)
            case .upArrow: return isTV ? nil : KeyData(key: .upArrow)
            case .downArrow: return isTV ? nil : KeyData(key: .downArrow)
            case .leftArrow: return isTV ? nil : KeyData(key: .leftArrow)
            case .rightArrow: return isTV ? nil : KeyData(key: .rightArrow)
            default: return nil
            }
        }

        /// Stable `UITouch` identity → pointer ID (H07, D30): `UITouch` instances are reused by
        /// UIKit across a touch's own lifetime and never across two different touches, so
        /// `ObjectIdentifier` is a correct and cheap key. Entries are added at `touchesBegan`
        /// and removed at `touchesEnded`/`touchesCancelled` — the only two terminal callbacks
        /// UIKit is documented to always eventually deliver for a tracked touch.
        private var touchPointerIDs: [ObjectIdentifier: UInt64] = [:]
        private var nextPointerID: UInt64 = 0

        /// Starts a pointer session per new touch (H07, D22 implicit capture): `bridge.send`
        /// resolves each one's target from the current commit and enforces single-touch
        /// (D30) — a second simultaneous touch is refused deterministically by
        /// `PointerSessions`, without this adapter needing to pick a "winner" itself.
        ///
        /// Ownership: borrows `touches`/`event`. Isolation: MainActor. Errors: a non-finite
        /// location sends nothing for that touch. Cancellation: not applicable.
        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            for touch in orderedDeterministically(touches) {
                // A touch this view is already tracking got here twice in the same real touch
                // sequence — `TrellisTouchObserver`'s forwarded call and UIKit's own direct
                // delivery to this view both fire when this view itself is the hit-tested one
                // (not only when a subview like a `ScrollNode`'s `UIScrollView` intercepts it).
                // `pointerUp`/`pointerCancel` are already naturally idempotent below (their
                // `removeValue(forKey:)` finds nothing the second time); `pointerDown` needs
                // this explicit guard since it has no such natural no-op path.
                guard touchPointerIDs[ObjectIdentifier(touch)] == nil else { continue }
                guard let data = pointerData(for: touch, pointerID: allocatePointerID(for: touch))
                else { continue }

                bridge?.send(.pointerDown, data)
            }
        }

        /// Continues each touch's session, wherever the pointer is now (D27: the route was
        /// fixed at `touchesBegan`, not re-hit-tested here).
        ///
        /// Ownership: borrows `touches`/`event`. Isolation: MainActor. Errors: a non-finite
        /// location sends nothing for that touch. Cancellation: not applicable.
        public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            for touch in orderedDeterministically(touches) {
                guard let id = touchPointerIDs[ObjectIdentifier(touch)],
                    let data = pointerData(for: touch, pointerID: id)
                else { continue }

                bridge?.send(.pointerMove, data)
            }
        }

        /// Ends each touch's session and releases its pointer ID for reuse.
        ///
        /// Ownership: borrows `touches`/`event`. Isolation: MainActor. Errors: a non-finite
        /// location sends nothing for that touch (the id is still released). Cancellation: not
        /// applicable.
        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            for touch in orderedDeterministically(touches) {
                guard let id = touchPointerIDs.removeValue(forKey: ObjectIdentifier(touch))
                else { continue }
                guard let data = pointerData(for: touch, pointerID: id) else { continue }

                bridge?.send(.pointerUp, data)
            }
        }

        /// Cancels each touch's session — the same `pointerCancel` path a host lifecycle
        /// cancel uses (H04); releases its pointer ID for reuse.
        ///
        /// Ownership: borrows `touches`/`event`. Isolation: MainActor. Errors: a non-finite
        /// location sends nothing for that touch (the id is still released). Cancellation:
        /// this is one.
        public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            for touch in orderedDeterministically(touches) {
                guard let id = touchPointerIDs.removeValue(forKey: ObjectIdentifier(touch))
                else { continue }
                guard let data = pointerData(for: touch, pointerID: id) else { continue }

                bridge?.send(.pointerCancel, data)
            }
        }

        /// `touches` is a `Set`, whose iteration order is not itself meaningful; sorting by
        /// `timestamp` (stably) makes the order this adapter sends events in reproducible
        /// within one run for a fixed input, without claiming any cross-process guarantee.
        private func orderedDeterministically(_ touches: Set<UITouch>) -> [UITouch] {
            touches.sorted { $0.timestamp < $1.timestamp }
        }

        private func allocatePointerID(for touch: UITouch) -> UInt64 {
            let key = ObjectIdentifier(touch)
            if let existing = touchPointerIDs[key] { return existing }

            nextPointerID &+= 1
            touchPointerIDs[key] = nextPointerID
            return nextPointerID
        }

        /// `touch.location(in:)` in this view's own top-left space — already the space
        /// `PointerData.point` expects. `nil` for a non-finite location: the adapter rejects it
        /// before it becomes a `PointerData` (D30), same as `TrellisAppKit`.
        private func pointerData(for touch: UITouch, pointerID: UInt64) -> PointerData? {
            let point = touch.location(in: self)
            guard point.x.isFinite, point.y.isFinite else { return nil }

            return PointerData(
                point: LayoutPoint(x: Double(point.x), y: Double(point.y)),
                pointerID: pointerID
            )
        }
    }

    /// See `TrellisHostView.installTouchObserver()`'s doc comment for why this exists. Never
    /// transitions `state` away from its initial `.possible` — a deliberately passive observer,
    /// not a recognizer that ever "wins": it never calls `failRequirement`/competes for
    /// recognition, so it cannot cancel or delay any other recognizer or view's own touch
    /// handling (`UIScrollView`'s pan, `TransitionGestureController`'s pan, a plain `UIButton`).
    /// This is the standard UIKit pattern for a container that must observe every touch that
    /// occurs within its bounds regardless of which of its subviews actually gets hit-tested.
    ///
    /// Living in `.possible` forever is exactly what trips UIKit's own idle-recognizer watchdog
    /// (confirmed live, R08, iPad trackpad session): `<TrellisTouchObserver: 0x...> has been in
    /// possible phase for NN seconds` printed to the console after roughly a minute of hover/
    /// pointer activity with no in-flight touch. Harmless and expected — this recognizer is
    /// never meant to resolve into `.recognized`/`.failed`, and touch delivery kept working
    /// correctly through and after the warning in that same session — not a sign of a stuck or
    /// leaked recognizer. Documented here so it is not mistaken for a real bug later.
    ///
    /// Ownership: retains no strong reference to `host` (`weak`), so it never keeps the view
    /// alive; `TrellisHostView` retains this recognizer via `addGestureRecognizer(_:)`.
    /// Isolation: MainActor (`UIGestureRecognizer` callbacks run on the main thread; `host`'s
    /// handlers require it). Errors: none. Cancellation: not applicable — removed automatically
    /// when the host view is deallocated.
    @MainActor
    private final class TrellisTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private weak var host: TrellisHostView?

        init(host: TrellisHostView) {
            self.host = host
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        // Without this, UIKit's default conflict policy between this ancestor observer and a
        // `ScrollNode`'s own `UIScrollView` pan gesture recognizer (a descendant, actively
        // recognizing) silently stops delivering `touchesMoved/Ended/Cancelled` to this observer
        // once the pan recognizer begins — found live on device (R08/defect #75): a real drag
        // left `touchesEnded` never forwarded, so `TrellisHostView`'s `touchPointerIDs`/
        // `PointerSessions` (D30's single-touch enforcement) kept treating that session as still
        // open, silently refusing every subsequent tap's `pointerDown` until some *later*
        // gesture happened to flush it. Returning `true` unconditionally is safe: this observer
        // never itself recognizes (`state` never leaves `.possible`), so it never competes for
        // exclusivity — it only needs UIKit's permission to keep *observing* every phase
        // alongside whichever descendant recognizer (the scroll view's pan, `TransitionGesture
        // Controller`'s pan, a plain control) actually drives the gesture.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            host?.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesMoved(touches, with: event)
            host?.touchesMoved(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            host?.touchesEnded(touches, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            host?.touchesCancelled(touches, with: event)
        }
    }
#endif
