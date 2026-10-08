#if canImport(UIKit)
    import UIKit

    import TrellisCore
    import TrellisRender

    /// One native object per committed node for the tvOS focus system and for VoiceOver (A08/
    /// A09, D44/D47): a `UIAccessibilityElement` that is also a `UIFocusItem`, with no
    /// `UIView` behind it — the mechanism proven in A02. Frames are the node's committed
    /// visible bounds in host space (the container's coordinate space); the accessibility
    /// frame is that box converted to screen space on demand. Reused by `(mountEpoch,
    /// NodeID)`; a proxy of a previous mount is dropped, never revived.
    ///
    /// Ownership: owned by `NativeProxyCoordinator`; holds its coordinator weakly and no
    /// `Node`. Isolation: MainActor. Errors: none. Cancellation: dropped when its node leaves
    /// the published snapshot or the host detaches.
    @MainActor
    final class TrellisNodeProxy: UIAccessibilityElement, UIFocusItem {
        let identity: NodeID
        let mountEpoch: UInt64
        private(set) var focusFrame: CGRect = .zero
        private(set) var isFocusCandidate = false
        private weak var coordinator: NativeProxyCoordinator?
        private weak var container: UIView?

        init(
            identity: NodeID,
            mountEpoch: UInt64,
            container: UIView,
            coordinator: NativeProxyCoordinator
        ) {
            self.identity = identity
            self.mountEpoch = mountEpoch
            self.container = container
            self.coordinator = coordinator
            super.init(accessibilityContainer: container)
        }

        /// Refreshes the focus side from a published record (A08).
        func updateFocus(from record: SemanticSnapshot.Record, inScope: Bool) {
            isFocusCandidate = inScope && record.isFocusCandidate
            focusFrame = record.visibleBounds.map(Self.cgRect) ?? .zero
        }

        private var hostFrame: CGRect = .zero
        private var hasSemanticPresence = false

        /// Refreshes the accessibility side from a published element (A09, A01 §3.1): a leaf
        /// is an element with label/value/hint/identifier and traits from its role and state;
        /// a group is a semantic container of its children's proxies, with the group label.
        /// Only the published values are stored — nothing reads live `Node` metadata later.
        func updateAccessibility(from element: AccessibilityElement, children: [TrellisNodeProxy]) {
            hasSemanticPresence = true
            hostFrame = Self.cgRect(element.frame)
            if focusFrame == .zero { focusFrame = hostFrame }
            isAccessibilityElement = element.isElement
            accessibilityLabel = element.label
            accessibilityValue = element.isElement ? element.value : nil
            accessibilityHint = element.isElement ? element.hint : nil
            accessibilityIdentifier = element.identifier
            accessibilityTraits = Self.traits(for: element)
            accessibilityElements = element.isElement ? nil : children
            accessibilityContainerType = element.isElement ? .none : .semanticGroup
            if element.isElement, !element.customActions.isEmpty {
                accessibilityCustomActions = element.customActions.map { action in
                    UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                        guard let self else { return false }

                        return self.coordinator?.perform(.custom(action.id), on: self) ?? false
                    }
                }
            } else {
                accessibilityCustomActions = nil
            }
        }

        /// Whether the published tree currently shows this node — a proxy kept only as a focus
        /// item reports nothing to VoiceOver.
        var isPublishedElement: Bool { hasSemanticPresence }

        static func traits(for element: AccessibilityElement) -> UIAccessibilityTraits {
            var traits: UIAccessibilityTraits = []
            if element.isElement {
                switch element.role {
                case .button: traits.insert(.button)
                case .text: traits.insert(.staticText)
                case .image: traits.insert(.image)
                case .header: traits.insert(.header)
                case .link: traits.insert(.link)
                case .adjustable: traits.insert(.adjustable)
                case .group, nil: break
                }
                if element.isSelected { traits.insert(.selected) }
            }
            if !element.isEnabled { traits.insert(.notEnabled) }
            return traits
        }

        // MARK: UIAccessibilityElement

        /// Screen-space frame of the visible area (D46), converted through the host on every
        /// read — a moved window changes the answer without a new layout pass.
        override var accessibilityFrame: CGRect {
            get {
                guard let container else { return .zero }

                return UIAccessibility.convertToScreenCoordinates(hostFrame, in: container)
            }
            set {}
        }

        override func accessibilityActivate() -> Bool {
            coordinator?.perform(.activate, on: self) ?? false
        }

        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            coordinator?.scroll(direction, on: self) ?? false
        }

        override func accessibilityIncrement() {
            _ = coordinator?.perform(.increment, on: self)
        }

        override func accessibilityDecrement() {
            _ = coordinator?.perform(.decrement, on: self)
        }

        static func cgRect(_ frame: LayoutFrame) -> CGRect {
            CGRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        }

        // MARK: UIFocusItem

        var canBecomeFocused: Bool { isFocusCandidate }
        var frame: CGRect { focusFrame }

        // MARK: UIFocusEnvironment

        var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
        var parentFocusEnvironment: (any UIFocusEnvironment)? { container }
        var focusItemContainer: (any UIFocusItemContainer)? { container }

        func setNeedsFocusUpdate() {
            UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self)
        }

        func updateFocusIfNeeded() {
            UIFocusSystem.focusSystem(for: self)?.updateFocusIfNeeded()
        }

        func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }

        func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            let next = context.nextFocusedItem as? TrellisNodeProxy
            if next === self {
                self.coordinator?.nativeFocusDidLand(on: self)
            } else if context.previouslyFocusedItem === self, next == nil {
                self.coordinator?.nativeFocusDidLeave(from: self)
            }
        }
    }

    /// The host view's registry of native proxies and the single writer of the tvOS focus
    /// handshake (A08, D44/D45): engine → pending request → `preferredFocusEnvironments` →
    /// `didUpdateFocus` → `bridge.focus(id, reason: .native)`. Only a transition the platform
    /// reported is mirrored back, and a transition the engine itself initiated is never sent
    /// back to it — the origin guard against a feedback loop.
    ///
    /// Ownership: owns the proxies; holds the bridge and host weakly. Isolation: MainActor.
    /// Errors: a native focus on a stale proxy is refused by the engine and ignored here.
    /// Cancellation: `removeAll()` on detach; `cancelPendingRequest()` on window loss.
    @MainActor
    final class NativeProxyCoordinator {
        private weak var host: UIView?
        private weak var bridge: NodeHostBridge?
        private var proxies: [NodeID: TrellisNodeProxy] = [:]
        private(set) var focusItems: [TrellisNodeProxy] = []
        private(set) var mountEpoch: UInt64 = 0
        /// The engine transition awaiting native confirmation (D44), or `nil`.
        private(set) var pendingNativeRequest: NodeID?
        /// Whether the platform focus system drives focus here — tvOS (D44). Elsewhere the
        /// engine is the only owner and no focus items are exposed.
        var isNativeFocusEnabled = false

        init(host: UIView, bridge: NodeHostBridge) {
            self.host = host
            self.bridge = bridge
        }

        /// Number of live proxies — an A12 ownership hook.
        var proxyCount: Int { proxies.count }

        /// Proxies created over this coordinator's lifetime: with `proxyCount` it says how
        /// many publishes reused their proxies instead of allocating (A12).
        private(set) var createdProxyTotal = 0

        /// Top-level accessibility elements in reading order — what the host's
        /// `accessibilityElements` returns (A09).
        private(set) var accessibilityRoots: [TrellisNodeProxy] = []

        /// Routes an assistive-technology action to the bridge, which validates the identity
        /// against the published tree and the live node before anything runs (D43). A proxy of
        /// a previous mount — the OS may still hold one after a detach/attach of the same root,
        /// whose `NodeID`s are valid again — is refused by epoch first (D47).
        func perform(_ action: AccessibilityAction, on proxy: TrellisNodeProxy) -> Bool {
            guard proxy.mountEpoch == mountEpoch, proxies[proxy.identity] === proxy else {
                Log.on(.event, "ax-action-rejected", node: proxy.identity, "reason=stale-proxy")
                return false
            }

            return bridge?.performAccessibilityAction(action, on: proxy.identity) ?? false
        }

        func scroll(_ direction: UIAccessibilityScrollDirection, on proxy: TrellisNodeProxy) -> Bool
        {
            guard proxy.mountEpoch == mountEpoch, proxies[proxy.identity] === proxy,
                proxy.isPublishedElement
            else { return false }
            let mapped: FocusDirection
            switch direction {
            case .up: mapped = .up
            case .down: mapped = .down
            case .left: mapped = .left
            case .right: mapped = .right
            case .next:
                let directions = bridge?.accessibilityScrollDirections(from: proxy.identity) ?? []
                mapped = directions.contains(.down) ? .down : .right
            case .previous:
                let directions = bridge?.accessibilityScrollDirections(from: proxy.identity) ?? []
                mapped = directions.contains(.up) ? .up : .left
            @unknown default: return false
            }
            let handled = bridge?.scrollAccessibility(mapped, from: proxy.identity) ?? false
            if handled { UIAccessibility.post(notification: .pageScrolled, argument: nil) }
            return handled
        }

        /// R08: reveal first; only the subsequent native callback assigns the new focus.
        func revealFocus(_ direction: FocusDirection) -> Bool {
            guard isNativeFocusEnabled, let bridge,
                let target = bridge.revealFocusTarget(direction),
                let proxy = proxies[target], proxy.canBecomeFocused, let host
            else { return false }
            pendingNativeRequest = target
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
            return true
        }

        func proxy(for identity: NodeID) -> TrellisNodeProxy? { proxies[identity] }

        /// Rebuilds the proxy set from a published snapshot: one proxy per committed node that
        /// is a focus candidate or has a semantic presence, reused by identity within the
        /// mount; everything else is dropped (D47).
        func apply(snapshot: SemanticSnapshot, tree: AccessibilityTree?, scope: NodeID?) {
            guard let host else { return }

            if snapshot.mountEpoch != mountEpoch {
                proxies.removeAll()
                focusItems.removeAll()
                pendingNativeRequest = nil
                mountEpoch = snapshot.mountEpoch
            }
            var keep: Set<NodeID> = []
            var items: [TrellisNodeProxy] = []
            let candidates = snapshot.focusCandidates(scope: scope)
            for id in candidates {
                guard let record = snapshot.record(for: id) else { continue }

                let proxy = ensureProxy(id, container: host)
                proxy.updateFocus(from: record, inScope: true)
                keep.insert(id)
                items.append(proxy)
            }
            var roots: [TrellisNodeProxy] = []
            if let tree {
                // Children before parents, so a group's `accessibilityElements` refers to
                // proxies that already carry their own published values.
                var ordered: [AccessibilityElement] = []
                var walk = Array(tree.elements.reversed())
                while let element = walk.popLast() {
                    ordered.append(element)
                    walk.append(contentsOf: element.children.reversed())
                }
                for element in ordered.reversed() {
                    let proxy = ensureProxy(element.id, container: host)
                    if !keep.contains(element.id), let record = snapshot.record(for: element.id) {
                        proxy.updateFocus(from: record, inScope: false)
                    }
                    keep.insert(element.id)
                    let children = element.children.compactMap { proxies[$0.id] }
                    proxy.updateAccessibility(from: element, children: children)
                }
                roots = tree.elements.compactMap { proxies[$0.id] }
            }
            for id in proxies.keys where !keep.contains(id) {
                proxies[id] = nil
            }
            focusItems = items
            accessibilityRoots = roots
            Log.on(
                .focus,
                "proxies",
                host: bridge?.hostID,
                "count=\(proxies.count) focusItems=\(items.count) epoch=\(mountEpoch)"
            )
        }

        private func ensureProxy(_ id: NodeID, container: UIView) -> TrellisNodeProxy {
            if let existing = proxies[id] { return existing }

            let proxy = TrellisNodeProxy(
                identity: id,
                mountEpoch: mountEpoch,
                container: container,
                coordinator: self
            )
            proxies[id] = proxy
            createdProxyTotal += 1
            return proxy
        }

        /// Focus items intersecting `rect` — what the host's `focusItems(in:)` adds to
        /// `super`'s (tvOS only).
        func focusItems(in rect: CGRect) -> [any UIFocusItem] {
            guard isNativeFocusEnabled else { return [] }

            return focusItems.filter { $0.canBecomeFocused && $0.frame.intersects(rect) }
        }

        /// The proxy the host asks the platform to focus: the pending engine request, else the
        /// engine's current focus (D44).
        var preferredFocusEnvironments: [any UIFocusEnvironment] {
            guard isNativeFocusEnabled else { return [] }

            let wanted = pendingNativeRequest ?? bridge?.focusedID
            guard let wanted, let proxy = proxies[wanted], proxy.canBecomeFocused else { return [] }

            return [proxy]
        }

        /// The engine moved focus (D44): on tvOS a transition the engine initiated becomes a
        /// pending request the platform is asked to honour; a `.native` transition is the
        /// platform's own report and is never sent back (D45).
        func engineFocusChanged(_ change: FocusChange) {
            guard isNativeFocusEnabled, change.reason != .native else { return }

            pendingNativeRequest = change.next
            guard let host else { return }

            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
        }

        /// The platform focused `proxy` — the native confirmation (D44), or a native move the
        /// engine did not initiate (an arrow on the Siri Remote); either way the engine follows.
        func nativeFocusDidLand(on proxy: TrellisNodeProxy) {
            let confirmed = pendingNativeRequest == proxy.identity
            pendingNativeRequest = nil
            guard proxy.mountEpoch == mountEpoch else { return }

            Log.on(.focus, "native-focus", node: proxy.identity, "confirmed=\(confirmed)")
            bridge?.focus(proxy.identity, reason: .native)
        }

        /// The platform moved focus away from `proxy` to something that is not ours (a
        /// neighbouring native control): the engine's focus is cleared, with its identity kept
        /// for restoration by the engine's own rules.
        func nativeFocusDidLeave(from proxy: TrellisNodeProxy) {
            guard proxy.mountEpoch == mountEpoch, bridge?.focusedID == proxy.identity else {
                return
            }

            Log.on(.focus, "native-focus-left", node: proxy.identity)
            bridge?.focus(nil, reason: .native)
        }

        func cancelPendingRequest() { pendingNativeRequest = nil }

        func removeAll() {
            proxies.removeAll()
            focusItems.removeAll()
            accessibilityRoots.removeAll()
            pendingNativeRequest = nil
        }
    }
#endif
