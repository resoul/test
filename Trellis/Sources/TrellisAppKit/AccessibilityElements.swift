#if canImport(AppKit)
    import AppKit

    import TrellisCore
    import TrellisRender

    /// One real `NSAccessibilityElement` per published semantic node (A10, D46/D47): the host
    /// view's accessibility children, with role, label, value, help, identifier, state, a
    /// screen-space frame and the actions VoiceOver can perform — no `NSView` per node. Values
    /// are set from the published tree at publish time and never read live from a `Node`;
    /// frames are recomputed from the stored host-space box when the window moves.
    ///
    /// Not `@MainActor`: `NSAccessibilityElement` is not isolated in the SDK, so its action
    /// overrides are nonisolated. AppKit calls them on the main thread; each hop back to the
    /// bridge goes through `MainActor.assumeIsolated` capturing only the coordinator and the
    /// identity — never `self`.
    ///
    /// Ownership: owned by `AppKitAccessibilityCoordinator`; holds it weakly and no `Node`.
    /// Isolation: main thread by AppKit contract. Errors: an action on a stale element returns
    /// `false`. Cancellation: dropped when its node leaves the published tree or the host
    /// detaches.
    final class TrellisAccessibilityElement: NSAccessibilityElement {
        let identity: NodeID
        let mountEpoch: UInt64
        private weak var coordinator: AppKitAccessibilityCoordinator?
        /// Host-space box of the visible area (D46), kept so a window move can recompute
        /// the screen frame without a layout pass.
        private(set) var hostFrame: CGRect = .zero

        init(identity: NodeID, mountEpoch: UInt64, coordinator: AppKitAccessibilityCoordinator) {
            self.identity = identity
            self.mountEpoch = mountEpoch
            self.coordinator = coordinator
            super.init()
        }

        /// Applies one published element (A01 §3.1): role by mapping (a header reads as static
        /// text — AppKit has no heading role for an arbitrary element), label/value/help/
        /// identifier, enabled/selected, and the children of a group.
        @MainActor
        func update(from element: AccessibilityElement, children: [TrellisAccessibilityElement]) {
            hostFrame = CGRect(
                x: element.frame.origin.x,
                y: element.frame.origin.y,
                width: element.frame.width,
                height: element.frame.height
            )
            setAccessibilityRole(Self.role(for: element))
            setAccessibilityLabel(element.label)
            setAccessibilityValue(element.isElement ? element.value : nil)
            setAccessibilityHelp(element.isElement ? element.hint : nil)
            setAccessibilityIdentifier(element.identifier ?? "")
            setAccessibilityEnabled(element.isEnabled)
            setAccessibilitySelected(element.isElement && element.isSelected)
            setAccessibilityElement(true)
            setAccessibilityChildren(element.isElement ? nil : children)
            if element.isElement, !element.customActions.isEmpty {
                let coordinator = self.coordinator
                let identity = self.identity
                let epoch = mountEpoch
                setAccessibilityCustomActions(
                    element.customActions.map { action in
                        NSAccessibilityCustomAction(name: action.name) {
                            MainActor.assumeIsolated {
                                coordinator?.perform(.custom(action.id), on: identity, epoch: epoch)
                                    ?? false
                            }
                        }
                    }
                )
            } else {
                setAccessibilityCustomActions(nil)
            }
            let coordinator = self.coordinator
            let identity = self.identity
            let epoch = mountEpoch
            let scrollActions = (coordinator?.scrollDirections(on: identity) ?? []).map {
                direction in
                let name: String
                switch direction {
                case .up:
                    name = NSLocalizedString("Scroll up", comment: "Accessibility scroll action")
                case .down:
                    name = NSLocalizedString("Scroll down", comment: "Accessibility scroll action")
                case .left:
                    name = NSLocalizedString("Scroll left", comment: "Accessibility scroll action")
                default:
                    name = NSLocalizedString("Scroll right", comment: "Accessibility scroll action")
                }
                return NSAccessibilityCustomAction(name: name) {
                    MainActor.assumeIsolated {
                        coordinator?.scroll(direction, on: identity, epoch: epoch) ?? false
                    }
                }
            }
            setAccessibilityCustomActions((accessibilityCustomActions() ?? []) + scrollActions)
        }

        /// Recomputes the screen frame from `hostFrame` through the host view — flipped host
        /// space → window → screen, all in the adapter (D46).
        @MainActor
        func updateScreenFrame(host: NSView) {
            let windowRect = host.convert(hostFrame, to: nil)
            setAccessibilityFrame(host.window?.convertToScreen(windowRect) ?? windowRect)
        }

        static func role(for element: AccessibilityElement) -> NSAccessibility.Role {
            guard element.isElement else { return .group }

            switch element.role {
            case .button: return .button
            case .text, .header: return .staticText
            case .image: return .image
            case .link: return .link
            case .group: return .group
            case .adjustable: return .slider
            case nil: return element.label == nil ? .group : .staticText
            }
        }

        // MARK: Actions (nonisolated by SDK contract; main thread by AppKit contract)

        override func accessibilityPerformPress() -> Bool { perform(.activate) }

        override func accessibilityPerformIncrement() -> Bool { perform(.increment) }

        override func accessibilityPerformDecrement() -> Bool { perform(.decrement) }

        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
            switch selector {
            case #selector(accessibilityPerformPress):
                return accessibilityRole() == .button
            case #selector(accessibilityPerformIncrement), #selector(accessibilityPerformDecrement):
                return accessibilityRole() == .slider
            default:
                return super.isAccessibilitySelectorAllowed(selector)
            }
        }

        private func perform(_ action: AccessibilityAction) -> Bool {
            let coordinator = self.coordinator
            let identity = self.identity
            let epoch = mountEpoch
            return MainActor.assumeIsolated {
                coordinator?.perform(action, on: identity, epoch: epoch) ?? false
            }
        }
    }

    /// The AppKit host's registry of accessibility elements (A10, D47): built from every
    /// published tree, reused by `(mountEpoch, NodeID)`, announced to the system after the
    /// elements already carry the new state, torn down on detach.
    ///
    /// Ownership: owns the elements; holds the host and bridge weakly. Isolation: MainActor.
    /// Errors: none. Cancellation: `removeAll()`.
    @MainActor
    final class AppKitAccessibilityCoordinator {
        private weak var host: NSView?
        private weak var bridge: NodeHostBridge?
        private var elements: [NodeID: TrellisAccessibilityElement] = [:]
        private(set) var roots: [TrellisAccessibilityElement] = []
        private(set) var mountEpoch: UInt64 = 0
        private var lastValues: [NodeID: String?] = [:]

        /// Observes what this coordinator posts — a test hook; `NSAccessibility.post` itself
        /// is not observable from a unit test.
        var notificationSink: ((NSAccessibility.Notification, NodeID?) -> Void)?

        init(host: NSView, bridge: NodeHostBridge) {
            self.host = host
            self.bridge = bridge
        }

        /// Number of live elements — an A12 ownership hook.
        var elementCount: Int { elements.count }

        /// Elements created over this coordinator's lifetime (A12): reuse means this stays at
        /// the tree size across commits.
        private(set) var createdElementTotal = 0

        func scrollDirections(on identity: NodeID) -> [FocusDirection] {
            bridge?.accessibilityScrollDirections(from: identity) ?? []
        }

        func scroll(_ direction: FocusDirection, on identity: NodeID, epoch: UInt64) -> Bool {
            guard epoch == mountEpoch, elements[identity] != nil else { return false }
            return bridge?.scrollAccessibility(direction, from: identity) ?? false
        }

        func element(for identity: NodeID) -> TrellisAccessibilityElement? { elements[identity] }

        /// Routes an action to the bridge's live guard (D43). An element of a previous mount —
        /// the OS may still hold one after a detach/attach of the same root, whose `NodeID`s
        /// are valid again — is refused by epoch before the bridge is asked (D47).
        func perform(_ action: AccessibilityAction, on identity: NodeID, epoch: UInt64) -> Bool {
            guard epoch == mountEpoch, elements[identity] != nil else {
                Log.on(.event, "ax-action-rejected", node: identity, "reason=stale-element")
                return false
            }

            return bridge?.performAccessibilityAction(action, on: identity) ?? false
        }

        /// Replaces the published set from `tree` — children before parents so a group's
        /// children already carry their values — then announces: `.layoutChanged` on the host
        /// (never on `NSApplication`, D47) when structure or frames changed, `.valueChanged` on
        /// each leaf whose value changed.
        func apply(tree: AccessibilityTree) {
            guard let host else { return }

            if tree.mountEpoch != mountEpoch {
                elements.removeAll()
                roots.removeAll()
                lastValues.removeAll()
                mountEpoch = tree.mountEpoch
            }
            var ordered: [AccessibilityElement] = []
            var walk = Array(tree.elements.reversed())
            while let element = walk.popLast() {
                ordered.append(element)
                walk.append(contentsOf: element.children.reversed())
            }
            var keep: Set<NodeID> = []
            var valueChanged: [TrellisAccessibilityElement] = []
            for element in ordered.reversed() {
                let native = ensureElement(element.id)
                let children = element.children.compactMap { elements[$0.id] }
                native.update(from: element, children: children)
                native.updateScreenFrame(host: host)
                for child in children { child.setAccessibilityParent(native) }
                keep.insert(element.id)
                if element.isElement, lastValues[element.id] != nil,
                    lastValues[element.id] != .some(element.value)
                {
                    valueChanged.append(native)
                }
                lastValues[element.id] = element.value
            }
            for id in elements.keys where !keep.contains(id) {
                elements[id] = nil
                lastValues[id] = nil
            }
            roots = tree.elements.compactMap { elements[$0.id] }
            for root in roots { root.setAccessibilityParent(host) }

            Log.on(
                .semantics,
                "ax-elements",
                host: bridge?.hostID,
                "count=\(elements.count) roots=\(roots.count) epoch=\(mountEpoch)"
            )
            notificationSink?(.layoutChanged, nil)
            NSAccessibility.post(element: host, notification: .layoutChanged)
            for native in valueChanged {
                notificationSink?(.valueChanged, native.identity)
                NSAccessibility.post(element: native, notification: .valueChanged)
            }
        }

        /// The window moved or resized without a layout change: screen frames follow from
        /// the stored host-space boxes (D46).
        func refreshScreenFrames() {
            guard let host else { return }

            for element in elements.values { element.updateScreenFrame(host: host) }
        }

        private func ensureElement(_ id: NodeID) -> TrellisAccessibilityElement {
            if let existing = elements[id] { return existing }

            let element = TrellisAccessibilityElement(
                identity: id,
                mountEpoch: mountEpoch,
                coordinator: self
            )
            elements[id] = element
            createdElementTotal += 1
            return element
        }

        func removeAll() {
            guard !elements.isEmpty || !roots.isEmpty else { return }

            elements.removeAll()
            roots.removeAll()
            lastValues.removeAll()
            if let host {
                notificationSink?(.layoutChanged, nil)
                NSAccessibility.post(element: host, notification: .layoutChanged)
            }
        }
    }
#endif
