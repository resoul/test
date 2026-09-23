#if canImport(AppKit)
    import AppKit

    import TrellisCore
    import TrellisRender

    /// Native boundary of a Trellis tree on macOS.
    ///
    /// `wantsLayer` and `isFlipped` make CALayer geometry use the same top-left convention as the
    /// shared renderer. Window notifications are filtered to this view's own `NSWindow`, so one
    /// window's activity cannot suspend another host.
    ///
    /// Ownership: retains its bridge; the bridge retains the mounted root and renderer.
    /// Isolation: MainActor. Errors: a root already owned by another host is not attached.
    /// Cancellation: `detach()` and window resignation suspend or cancel bridge work.
    @MainActor
    public final class TrellisHostView: NSView {
        private var bridge: NodeHostBridge?
        private var accessibilityElementsCoordinator: AppKitAccessibilityCoordinator?

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
        private weak var observedWindow: NSWindow?

        /// Coordinate origin at the top-left corner, matching UIKit platforms.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override var isFlipped: Bool { true }

        /// Backing scale factor of the window containing the host.
        ///
        /// Before being attached to a window the scale is unknown, so the value is `1`.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var hostScale: Double {
            hostScaleOverride ?? Double(window?.backingScaleFactor ?? 1)
        }

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

        /// Creates an empty host with layer-backing enabled.
        ///
        /// Ownership: the caller owns the view. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            installMouseObserver()
        }

        /// Creates a host from an unarchiver with layer-backing enabled.
        ///
        /// Ownership: AppKit owns the decoded view. Isolation: MainActor.
        /// Errors: decoding follows the AppKit contract. Cancellation: not applicable.
        public required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            installMouseObserver()
        }

        /// R08/defect #75 (ported from the UIKit host, see its `installTouchObserver()` doc):
        /// `mouseDown/Dragged/Up` below only fire when this view itself is the event's target —
        /// a `ScrollNode` embeds a real `NSScrollView` as a *subview* of this host
        /// (`NSScrollViewBacking.init`), so a click/drag inside it targets that subview instead.
        /// `TrellisMouseObserver` is an `NSGestureRecognizer` attached directly to this view:
        /// AppKit, like UIKit, delivers mouse events to gesture recognizers attached along the
        /// target view's superview chain regardless of which subview was actually targeted. It
        /// forwards every phase into this view's own handlers below.
        private func installMouseObserver() {
            addGestureRecognizer(TrellisMouseObserver(host: self))
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            // `installReduceMotionObserver`'s own registration is on a different center — see
            // its doc comment — so the line above alone would leak this one.
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }

        /// Attaches `root` using one consistent initial host state.
        ///
        /// Ownership: the bridge retains `root` until replacement or `detach`. Isolation:
        /// MainActor. Errors: an already-mounted root is rejected and this view becomes detached.
        /// Cancellation: replacing a root detaches the previous bridge and cancels its work.
        public func attach(root: Node) {
            detach()
            guard let bridge = ensureBridge() else { return }
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
                        NSScrollViewBacking(
                            nodeID: nodeID,
                            delegate: delegate,
                            superview: self ?? NSView()
                        )
                    }
                )
            else { return }

            bridge.isDebugOverlayEnabled = isDebugOverlayEnabled
            bridge.debugOverlayLabelStyle = debugOverlayLabelStyle
            installWindowObservers()
            needsLayout = true
        }

        /// Binds a `StateSubject` to a node-updating closure for the life of this view (C29):
        /// delivery follows `attach`/`detach` and window key state, see
        /// `NodeHostBridge.bindState(_:update:)`. Bindings outlive any one attached root, so
        /// the same view can show a fresh root with the current state after a detach/attach.
        /// Named `bindState` because `NSView` already has Cocoa's `bind(_:to:withKeyPath:)`.
        ///
        /// Ownership: the view's bridge retains the binding until `cancel()`. Isolation:
        /// MainActor. Errors: none. Cancellation: `StateBinding.cancel()`.
        @discardableResult
        public func bindState<Value: Sendable & Equatable>(
            _ subject: StateSubject<Value>,
            update: @escaping @MainActor (Value) -> Void
        ) -> StateBinding? {
            ensureBridge()?.bindState(subject, update: update)
        }

        /// This view's underlying bridge, creating it if needed — an escape hatch for API
        /// this view does not itself forward (e.g. `TrellisFlux`'s `bindFlux`, R05), without
        /// this module depending on whatever added it. Same lazy-creation rule as
        /// `bindState`: `nil` only when the view has no layer yet.
        ///
        /// Ownership: the view retains its bridge; a caller must not retain it past this
        /// view's own lifetime. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var hostBridge: NodeHostBridge? { ensureBridge() }

        /// The node with keyboard focus in this host, or `nil` (A08, D39).
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var focusedID: NodeID? { bridge?.focusedID }

        /// Called once per completed focus transition in this host (D39). Survives
        /// `attach`/`detach`.
        ///
        /// Ownership: the bridge retains the closure; it must not retain this view strongly.
        /// Isolation: MainActor. Errors: none. Cancellation: assign `nil`.
        public var onFocusChange: (@MainActor (FocusChange) -> Void)? {
            get { bridge?.onFocusChange }
            set { ensureBridge()?.onFocusChange = newValue }
        }

        /// Requests keyboard focus on a node, or clears it — see `NodeHostBridge.focus`.
        ///
        /// Ownership: nothing is retained. Isolation: MainActor. Errors: `.unavailable` without
        /// a mounted, committed tree. Cancellation: not applicable.
        @discardableResult
        public func focus(_ id: NodeID?) -> FocusMoveResult { bridge?.focus(id) ?? .unavailable }

        /// Moves keyboard focus in a direction — see `NodeHostBridge.moveFocus`.
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

        /// One bridge for the view's lifetime (so bindings survive `detach`), created on first
        /// use because the layer is only guaranteed after `wantsLayer`.
        private func ensureBridge() -> NodeHostBridge? {
            if let bridge { return bridge }
            guard let layer else { return nil }
            installLocaleObserver()
            installReduceMotionObserver()
            let bridge = NodeHostBridge(hostLayer: layer)
            self.bridge = bridge
            let coordinator = AppKitAccessibilityCoordinator(host: self, bridge: bridge)
            accessibilityElementsCoordinator = coordinator
            bridge.onAccessibilityTreeChanged = { [weak self] tree in
                self?.accessibilityElementsCoordinator?.apply(tree: tree)
            }
            return bridge
        }

        /// Number of native accessibility elements currently alive for this host — an A12
        /// ownership hook; bounded by the published tree, never by the number of commits.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var nativeAccessibilityElementCount: Int {
            accessibilityElementsCoordinator?.elementCount ?? 0
        }

        /// Elements created over this host's lifetime (A12): a steady tree must not grow it
        /// with commits.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var createdNativeAccessibilityElementTotal: Int {
            accessibilityElementsCoordinator?.createdElementTotal ?? 0
        }

        /// The element registry — a test hook, never a render path.
        var accessibilityCoordinatorForTesting: AppKitAccessibilityCoordinator? {
            accessibilityElementsCoordinator
        }

        /// The host is a group container, never an element itself (A10): VoiceOver lands on
        /// the real `NSAccessibilityElement` children.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override func isAccessibilityElement() -> Bool { false }

        /// The host's role for the system accessibility tree.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override func accessibilityRole() -> NSAccessibility.Role? { .group }

        /// The published top-level elements in reading order (D42), confined to the modal
        /// scope when one is open (D40).
        ///
        /// Ownership: the elements stay owned by this view. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public override func accessibilityChildren() -> [Any]? {
            accessibilityElementsCoordinator?.roots ?? []
        }

        /// Detaches the current root and releases all bridge-owned work and layers. The bridge
        /// itself, and the state bindings it holds, stay for the next `attach`.
        ///
        /// Ownership: releases the retained root; keeps the bridge. Isolation: MainActor.
        /// Errors: none. Cancellation: cancels active layout work and pauses state delivery.
        public func detach() {
            removeWindowObservers()
            bridge?.detach()
            accessibilityElementsCoordinator?.removeAll()
            // Mirrors the UIKit host's `touchPointerIDs.removeAll()` on window loss: a press the
            // bridge just cancelled must not leave this view thinking a mouse session is still
            // open, or a later real `mouseDown` would be wrongly treated as this session's
            // duplicate delivery by the `hasActiveMouseSession` guard below and dropped.
            hasActiveMouseSession = false
        }

        /// Sends the current bounds and scale after AppKit has laid out this view.
        ///
        /// Ownership: borrows bridge state. Isolation: MainActor. Errors: none. Cancellation:
        /// newer bounds supersede pending layout work.
        public override func layout() {
            super.layout()
            updateBridgeState()
        }

        /// Captures backing-scale changes that do not change the view's bounds.
        ///
        /// Ownership: borrows bridge state. Isolation: MainActor. Errors: none. Cancellation:
        /// newer scale supersedes pending layout work.
        public override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            bridge?.updateBounds(currentBounds, scale: hostScale)
        }

        /// Rebinds lifecycle observation to this view's particular window.
        ///
        /// Ownership: borrows the current window and retains no observer token. Isolation:
        /// MainActor. Errors: none. Cancellation: leaving a window suspends bridge work.
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            guard window != nil else {
                bridge?.suspend()
                return
            }

            installWindowObservers()
            updateBridgeState()
            bridge?.resume()
        }

        private var currentBounds: LayoutFrame {
            LayoutFrame(width: Double(bounds.width), height: Double(bounds.height))
        }

        private var currentLayoutDirection: LayoutDirection {
            userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }

        /// The identifier `TextRendererKey`'s sibling `LocaleKey` receives at `attach` and
        /// whenever the system locale changes (T09) — `Locale.current` is a live snapshot, not
        /// itself observable, hence `localeDidChange` re-reading it on
        /// `NSLocale.currentLocaleDidChangeNotification`.
        private var currentLocaleIdentifier: String { Locale.current.identifier }

        /// The value `updateReduceMotion` receives at `attach` and whenever the system setting
        /// changes (D67) — `accessibilityDisplayShouldReduceMotion` is a live snapshot, not
        /// itself observable, hence `reduceMotionDidChange` re-reading it on
        /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
        private var currentReduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

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

        private func installWindowObservers() {
            guard let window else { return }
            observedWindow = window
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            // A moved window changes every element's screen frame without any layout (D46).
            center.addObserver(
                self,
                selector: #selector(windowDidMove(_:)),
                name: NSWindow.didMoveNotification,
                object: window
            )
        }

        private func removeWindowObservers() {
            guard let observedWindow else { return }
            let center = NotificationCenter.default
            center.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
            center.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: observedWindow
            )
            center.removeObserver(self, name: NSWindow.didMoveNotification, object: observedWindow)
            self.observedWindow = nil
        }

        @objc private func windowDidBecomeKey(_: Notification) {
            updateBridgeState()
            bridge?.resume()
        }

        @objc private func windowDidResignKey(_: Notification) {
            bridge?.suspend()
            // See `detach()`'s comment on the same field — resignation cancels any active press
            // at the bridge level the same way `detach()` does.
            hasActiveMouseSession = false
        }

        @objc private func windowDidMove(_: Notification) {
            accessibilityElementsCoordinator?.refreshScreenFrames()
        }

        /// Registered once per view (from `ensureBridge`, guarded by the bridge itself already
        /// being created only once) rather than per-window like `installWindowObservers` — a
        /// locale change is a system-wide event, not scoped to this host's window. `deinit`'s
        /// `NotificationCenter.default.removeObserver(self)` already covers this registration
        /// too, so no separate teardown is needed (T09).
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
        /// than per-window — Reduce Motion is a system-wide accessibility setting, not scoped to
        /// this host's window (D67). Unlike every other notification in this file,
        /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` posts on
        /// `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default` — `deinit`'s
        /// `NotificationCenter.default.removeObserver` does not reach it, so this registration
        /// is torn down explicitly.
        private func installReduceMotionObserver() {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(reduceMotionDidChange),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil
            )
        }

        @objc private func reduceMotionDidChange() {
            bridge?.updateReduceMotion(currentReduceMotion)
        }

        /// Identity of the mouse pointer for the whole life of this view (H08, D30): AppKit has
        /// no concurrent mouse sessions, so a fixed id is enough — `PointerSessions` allows
        /// reuse once a session has released, which `mouseUp` always does before the next
        /// `mouseDown`.
        private static let mousePointerID: UInt64 = 0

        /// Whether a mouse-down session is currently open (H08's single fixed pointer id has no
        /// per-touch dictionary to naturally dedupe against, unlike the UIKit host). Guards
        /// against the same real `mouseDown`/`mouseUp` reaching this view twice — once via
        /// AppKit's normal delivery to this view when it is itself the target, once forwarded by
        /// `TrellisMouseObserver` (R08/defect #75) — without which a click on ordinary content
        /// (not inside any `ScrollNode`) would double-activate. Reset by `detach()`/
        /// `windowDidResignKey` so a press the bridge cancels does not wedge this flag `true`.
        private var hasActiveMouseSession = false

        /// Starts a pointer session at the primary mouse button's down point (H08, D22
        /// implicit capture): `bridge.send` resolves the target from the current commit.
        /// Secondary and other buttons are never routed here — `rightMouseDown`/
        /// `otherMouseDown` are not overridden, so AppKit's own responder chain handles them
        /// (D30: non-primary buttons ignored).
        ///
        /// Ownership: borrows `event`. Isolation: MainActor. Errors: a non-finite location
        /// sends nothing. Cancellation: not applicable.
        public override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            window?.makeFirstResponder(self)
            guard !hasActiveMouseSession, let data = pointerData(for: event) else { return }

            hasActiveMouseSession = true
            bridge?.send(.pointerDown, data)
        }

        /// Continues the session started by `mouseDown` — AppKit only calls this while the
        /// button stays down, so there is always exactly one session to continue.
        ///
        /// Ownership: borrows `event`. Isolation: MainActor. Errors: a non-finite location
        /// sends nothing. Cancellation: not applicable.
        public override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            guard let data = pointerData(for: event) else { return }

            bridge?.send(.pointerMove, data)
        }

        /// Ends the session started by `mouseDown`.
        ///
        /// Ownership: borrows `event`. Isolation: MainActor. Errors: a non-finite location
        /// sends nothing. Cancellation: not applicable.
        public override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            guard hasActiveMouseSession else { return }
            hasActiveMouseSession = false
            guard let data = pointerData(for: event) else { return }

            bridge?.send(.pointerUp, data)
        }

        /// Keyboard focus needs a first responder: a click on the host claims it, so Tab and
        /// Return work right after the mouse without a separate focus gesture.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override var acceptsFirstResponder: Bool { true }

        /// Routes a key press to the focus engine (A08, D38/D43): Tab/Shift-Tab and the arrows
        /// move focus, Return and Space press the focused control. A key the engine does not
        /// consume — anything unmapped, or Tab at the boundary of this tree — goes on to
        /// `super`, and so up the responder chain to AppKit's own key-view traversal: the host
        /// is never a keyboard trap.
        ///
        /// Ownership: borrows `event`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override func keyDown(with event: NSEvent) {
            guard let data = Self.keyData(for: event), bridge?.send(.keyDown, key: data) == .handled
            else {
                super.keyDown(with: event)
                return
            }
        }

        /// Completes the press cycle Return/Space opened in `keyDown` — the activation happens
        /// here (D43). Unconsumed key-ups continue up the responder chain.
        ///
        /// Ownership: borrows `event`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override func keyUp(with event: NSEvent) {
            guard let data = Self.keyData(for: event), bridge?.send(.keyUp, key: data) == .handled
            else {
                super.keyUp(with: event)
                return
            }
        }

        /// `NSEvent` → `KeyData` for the keys the engine understands, `nil` for everything
        /// else. Virtual key codes are layout-independent for these keys (ANSI/ISO/JIS all
        /// agree on Tab, Return, Space and the arrows).
        static func keyData(for event: NSEvent) -> KeyData? {
            let key: KeyboardKey
            switch event.keyCode {
            case 48: key = .tab
            case 126: key = .upArrow
            case 125: key = .downArrow
            case 123: key = .leftArrow
            case 124: key = .rightArrow
            case 36, 76: key = .returnKey
            case 49: key = .space
            default: return nil
            }
            return KeyData(
                key: key,
                isShiftDown: event.modifierFlags.contains(.shift),
                isRepeat: event.isARepeat
            )
        }

        /// Converts `event`'s window-space location into this view's own flipped, top-left
        /// coordinate space (H08, D30) — `isFlipped` already matches the shared renderer's
        /// convention, so no further inversion is needed. `nil` for a non-finite location: the
        /// adapter rejects it before it becomes a `PointerData` (D30), same as `TrellisUIKit`.
        private func pointerData(for event: NSEvent) -> PointerData? {
            let local = convert(event.locationInWindow, from: nil)
            guard local.x.isFinite, local.y.isFinite else { return nil }

            return PointerData(
                point: LayoutPoint(x: Double(local.x), y: Double(local.y)),
                pointerID: Self.mousePointerID
            )
        }
    }

    /// See `TrellisHostView.installMouseObserver()`'s doc comment and the UIKit host's
    /// `TrellisTouchObserver` (same purpose, AppKit's mouse equivalent). Never transitions
    /// `state` away from its initial `.possible` — a passive observer, not a recognizer that
    /// ever "wins" recognition, so it cannot cancel or delay any other recognizer or view's own
    /// mouse handling (an `NSScrollView`'s own click-through, an overlay `NSButton`).
    ///
    /// Ownership: retains no strong reference to `host` (`weak`); `TrellisHostView` retains this
    /// recognizer via `addGestureRecognizer(_:)`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable — removed automatically when the host view is deallocated.
    @MainActor
    private final class TrellisMouseObserver: NSGestureRecognizer, NSGestureRecognizerDelegate {
        private weak var host: TrellisHostView?

        init(host: TrellisHostView) {
            self.host = host
            super.init(target: nil, action: nil)
            // AppKit's mouse equivalent of the UIKit host's `cancelsTouchesInView`/
            // `delaysTouchesBegan = false`: without this, the recognizer's default (`true`)
            // would withhold the primary mouse-down from its actual target — this view or a
            // `ScrollNode`'s `NSScrollView` — until the recognizer settled its own state, which
            // it deliberately never does.
            delaysPrimaryMouseButtonEvents = false
            delegate = self
        }

        // Ported from the UIKit host's `TrellisTouchObserver` after the live finding there
        // (R08/defect #75): without explicit permission, UIKit's (and by the same
        // `NSGestureRecognizer` design, AppKit's) default conflict policy between this ancestor
        // observer and a `ScrollNode`'s own `NSScrollView` scroll/click recognizers can stop
        // delivering `mouseDragged`/`mouseUp` to this observer once the descendant's own
        // recognizer begins. Safe unconditionally: this observer never transitions its own
        // `state` away from `.possible`, so it never competes for exclusivity.
        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool { true }

        required init?(coder: NSCoder) {
            // Created only in code by `installMouseObserver()`, never archived/restored — fails
            // decoding cleanly instead of trapping (`fatalError`/force operations are
            // disallowed outright, not just discouraged — AGENTS.md).
            return nil
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            host?.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            host?.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            host?.mouseUp(with: event)
        }
    }
#endif
