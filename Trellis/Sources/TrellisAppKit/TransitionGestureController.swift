#if canImport(AppKit)
    import AppKit
    import TrellisCore
    import TrellisRender

    /// M12: wires one real `NSPanGestureRecognizer` to `NodeHostBridge`'s gesture-progress entry
    /// points (`beginTransitionGesture()`/`updateTransitionGesture(deltaProgress:)`/
    /// `endTransitionGesture(velocity:)`/`cancelTransitionGestureSystemInterrupted()`) — the
    /// macOS half of M12's narrowly-scoped platform wiring (D73: "жест принимается через
    /// неподвижную host-overlay область"). `view` is that fixed region: the recognizer reads
    /// only its own `translation(in:)`/`velocity(in:)` against `view`'s coordinate space, never
    /// any moving transition layer's own frame/presentation geometry.
    ///
    /// Deliberately narrow — pointer-specific affordances (scroll-wheel/trackpad distinctions,
    /// right-click-to-dismiss, tvOS remote) are M13's "Touch на iOS, pointer на macOS; tvOS..."
    /// item, not this card's.
    ///
    /// Ownership: retains `bridge` and the `NSPanGestureRecognizer` it creates; `view` retains
    /// the recognizer too, per ordinary `NSView`/`NSGestureRecognizer` ownership. Isolation:
    /// MainActor — both `NSGestureRecognizer` and `NodeHostBridge` are main-actor-only. Errors:
    /// none — a call into `bridge` outside a valid gesture-input state is a diagnosed no-op on
    /// the bridge's side, not surfaced here. Cancellation: `detach()` removes the recognizer;
    /// `NSGestureRecognizer.State.cancelled`/`.failed` (a right-click or Escape interrupting the
    /// drag) resolves any live session deterministically via
    /// `cancelTransitionGestureSystemInterrupted()`, never leaving it stuck.
    @MainActor
    public final class TransitionGestureController: NSObject {
        private let bridge: NodeHostBridge
        private let distance: CGFloat
        private var recognizer: NSPanGestureRecognizer?

        /// Creates a controller. `distance` is how many points a full `0...1` progress sweep
        /// corresponds to (the fixed overlay region's own extent, D73) — e.g. the hosting view's
        /// height for a vertical dismiss gesture. Values `<= 0` are treated as `1` so a
        /// misconfigured distance cannot divide by zero.
        ///
        /// Ownership: retains `bridge`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(bridge: NodeHostBridge, distance: CGFloat) {
            self.bridge = bridge
            self.distance = distance > 0 ? distance : 1
            super.init()
        }

        /// Attaches an `NSPanGestureRecognizer` to `view` — the fixed host-overlay hit-test
        /// region (D73), not any moving transition layer. Replaces a previously attached
        /// recognizer, if any.
        ///
        /// Ownership: retains the created recognizer; `view` retains it too. Isolation:
        /// MainActor. Errors: none. Cancellation: `detach()` removes it.
        public func attach(to view: NSView) {
            detach()
            let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            view.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        /// Removes the recognizer from its view, if attached.
        ///
        /// Ownership: releases the recognizer. Isolation: MainActor. Errors: none. Cancellation:
        /// this call is one.
        public func detach() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        /// Exposed `internal` (not `private`) so `Tests/TrellisRenderTests` can drive it directly
        /// with a real `NSPanGestureRecognizer` instance under test — `NSGestureRecognizer`
        /// offers no public API to synthesize `.began`/`.changed`/`.ended` from mouse events
        /// outside a running AppKit event loop, so the deterministic tests call this the same
        /// way AppKit's own recognizer machinery would.
        @objc func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let view = recognizer.view else { return }

            switch recognizer.state {
            case .began:
                let translation = recognizer.translation(in: view)
                let location = recognizer.location(in: view)
                let accepted = bridge.beginTransitionGesture(
                    at: LayoutPoint(x: Double(location.x), y: Double(location.y)),
                    initialDelta: LayoutPoint(
                        x: Double(translation.x),
                        y: Double(translation.y)
                    )
                )
                if accepted { recognizer.setTranslation(.zero, in: view) }
            case .changed:
                let translation = recognizer.translation(in: view)
                bridge.updateTransitionGesture(deltaProgress: Double(translation.y / distance))
                recognizer.setTranslation(.zero, in: view)
            case .ended:
                let velocity = recognizer.velocity(in: view)
                _ = bridge.endTransitionGesture(velocity: Double(velocity.y / distance))
            case .cancelled, .failed:
                _ = bridge.cancelTransitionGestureSystemInterrupted()
            case .possible:
                break
            @unknown default:
                break
            }
        }
    }
#endif
