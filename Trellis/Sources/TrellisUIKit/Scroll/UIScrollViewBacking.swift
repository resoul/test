#if canImport(UIKit)
    import UIKit

    import TrellisCore
    import TrellisRender

    /// `NativeScrollBacking` over a real `UIScrollView` (R07) — generalizes R06's prototype
    /// (`Tests/TrellisRenderTests/UIKitNativeScrollEmbeddingPrototypeTests.swift`, which wrapped
    /// a whole `TrellisHostView`) to one `ScrollNode` anywhere in the tree: instead of the host
    /// becoming a `UIScrollView`'s subview, this creates its own `UIScrollView` and adds it as a
    /// direct subview of the host view passed at creation, positioned by `LayerRenderer` at the
    /// node's committed frame in host-absolute coordinates (`NativeScrollBacking.containerLayer`'s
    /// doc explains why this is a flat subview, not nested inside an ancestor's layer).
    ///
    /// Ownership: owns its `UIScrollView` and the installed content layer; the scroll view's
    /// `superview` retains it while attached. `dispose()` disconnects delegates, stops movement,
    /// resolves pending completion and removes the native view; the renderer owns that boundary.
    /// Isolation: MainActor. Errors: none. Cancellation: an in-flight animated `scroll(to:...)`
    /// is cancelled by a later call to the same method or by the user beginning a drag — both
    /// resolve the previous call's `completion` with `false` before this backing's own state
    /// moves on.
    @MainActor
    final class UIScrollViewBacking: NSObject, NativeScrollBacking, UIScrollViewDelegate {
        private let nodeID: NodeID
        private weak var delegate: (any NativeScrollBackingDelegate)?
        private let scrollView = UIScrollView()
        private let contentContainer = UIView()
        private var hostContentOrigin = LayoutPoint(x: 0, y: 0)
        private var installedContentLayer: CALayer?
        private var pendingAnimatedCompletion: (@MainActor (Bool) -> Void)?
        private var isAnimatingProgrammatically = false
        private var timedRevision: UInt64 = 0
        private static let timedKey = "trellis.timed-offset"

        /// Creates the backing's `UIScrollView` and adds it as a subview of `superview` — called
        /// once per committed `ScrollNode`, from the `NativeScrollBackingFactory` closure
        /// `TrellisHostView.attach(root:)` supplies.
        ///
        /// Ownership: retains `nodeID`/`delegate` (weakly); `superview` retains the created
        /// scroll view. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        init(nodeID: NodeID, delegate: any NativeScrollBackingDelegate, superview: UIView) {
            self.nodeID = nodeID
            self.delegate = delegate
            super.init()
            scrollView.delegate = self
            scrollView.clipsToBounds = true
            contentContainer.isUserInteractionEnabled = true
            scrollView.addSubview(contentContainer)
            superview.addSubview(scrollView)
        }

        var containerLayer: CALayer { scrollView.layer }

        func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?) {
            // `UIView.frame` is the source of truth UIKit's own touch hit-testing reads; setting
            // it (not `scrollView.layer.bounds`/`.position` directly) keeps that hit-testing
            // correct and leaves `contentOffset` (`layer.bounds.origin`) untouched (R07's
            // found-while-implementing note, `docs/validation/r07-scroll-node.md`).
            scrollView.frame = CGRect(
                x: frame.origin.x - (parentContentOrigin?.x ?? 0),
                y: frame.origin.y - (parentContentOrigin?.y ?? 0),
                width: frame.width,
                height: frame.height
            )
            hostContentOrigin = frame.origin
        }

        var contentOriginInHost: LayoutPoint { hostContentOrigin }

        func makeChildBacking(nodeID: NodeID) -> (any NativeScrollBacking)? {
            guard let delegate else { return nil }
            return UIScrollViewBacking(
                nodeID: nodeID,
                delegate: delegate,
                superview: contentContainer
            )
        }

        var viewportSize: MeasuredSize {
            MeasuredSize(
                width: Double(scrollView.bounds.width),
                height: Double(scrollView.bounds.height)
            )
        }

        var contentOffset: LayoutPoint {
            get {
                LayoutPoint(
                    x: Double(scrollView.contentOffset.x),
                    y: Double(scrollView.contentOffset.y)
                )
            }
            set {
                scrollView.contentOffset = CGPoint(x: newValue.x, y: newValue.y)
            }
        }

        func setContentSize(_ size: MeasuredSize) {
            let resolved = CGSize(width: size.width, height: size.height)
            guard scrollView.contentSize != resolved else { return }

            scrollView.contentSize = resolved
            contentContainer.frame = CGRect(origin: .zero, size: resolved)
        }

        func setInsets(_ insets: DirectionalEdgeInsets) {
            let physical = insets.resolved(
                for: scrollView.effectiveUserInterfaceLayoutDirection == .rightToLeft
                    ? .rightToLeft : .leftToRight
            )
            let resolved = UIEdgeInsets(
                top: physical.top,
                left: physical.left,
                bottom: physical.bottom,
                right: physical.right
            )
            guard scrollView.contentInset != resolved else { return }

            scrollView.contentInset = resolved
        }

        func apply(configuration: ScrollConfiguration) {
            scrollView.isScrollEnabled = configuration.userInteractionEnabled
            scrollView.isDirectionalLockEnabled = configuration.directionalLockEnabled
            scrollView.showsVerticalScrollIndicator =
                configuration.indicators == .automatic && configuration.axis != .horizontal
            scrollView.showsHorizontalScrollIndicator =
                configuration.indicators == .automatic && configuration.axis != .vertical
            scrollView.alwaysBounceVertical =
                configuration.bounce == .always && configuration.axis != .horizontal
            scrollView.alwaysBounceHorizontal =
                configuration.bounce == .always && configuration.axis != .vertical
            scrollView.bounces = configuration.bounce != .never
            scrollView.keyboardDismissMode =
                switch configuration.keyboardDismissMode {
                case .none: .none
                case .interactive: .interactive
                case .onDrag: .onDrag
                }
            // Trellis has already folded safe area into `setInsets(_:)` exactly once.
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        func installContentLayer(_ layer: CALayer) {
            installedContentLayer = layer
            contentContainer.layer.addSublayer(layer)
        }

        func removeContentLayer() {
            installedContentLayer?.removeFromSuperlayer()
            installedContentLayer = nil
        }

        func dispose() {
            // Disconnect before stopping motion: UIKit can synchronously emit a final tick.
            scrollView.delegate = nil
            delegate = nil
            scrollView.layer.removeAnimation(forKey: Self.timedKey)
            timedRevision &+= 1
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            scrollView.isScrollEnabled = false
            resolvePendingAnimatedCompletion(finished: false)
            scrollView.removeFromSuperview()
        }

        func scroll(
            to offset: LayoutPoint,
            animated: Bool,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            // A previous animated command still in flight is superseded, not left dangling —
            // `NodeHostBridge` itself already resolves the *caller-facing* outcome for its own
            // previous token before issuing a new one (§7); this is the backing's own native
            // completion bookkeeping for the same event.
            resolvePendingAnimatedCompletion(finished: false)
            stopTimedAnimation()
            let target = CGPoint(x: offset.x, y: offset.y)
            if animated {
                isAnimatingProgrammatically = true
                pendingAnimatedCompletion = completion
                scrollView.setContentOffset(target, animated: true)
            } else {
                scrollView.setContentOffset(target, animated: false)
                completion(true)
            }
        }

        func scroll(
            to offset: LayoutPoint,
            animation: TrellisCore.Animation,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            resolvePendingAnimatedCompletion(finished: false)
            stopTimedAnimation()
            let from = scrollView.bounds
            // The model moves at once (one `scrollViewDidScroll`); a Core Animation `bounds`
            // animation with the same timing `LayerAnimator` uses shows the movement, so nodes
            // animated with the same `Animation` move in step.
            scrollView.setContentOffset(CGPoint(x: offset.x, y: offset.y), animated: false)
            guard animation.duration > .zero, from != scrollView.bounds else {
                completion(true)
                return
            }

            timedRevision &+= 1
            let revision = timedRevision
            isAnimatingProgrammatically = true
            pendingAnimatedCompletion = completion
            let caAnimation = makeAnimation(keyPath: "bounds", timing: animation)
            caAnimation.fromValue = NSValue(cgRect: from)
            caAnimation.toValue = NSValue(cgRect: scrollView.bounds)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.timedRevision == revision else { return }

                    self.reportOffset(phase: .idle)
                    self.resolvePendingAnimatedCompletion(finished: true)
                }
            }
            scrollView.layer.add(caAnimation, forKey: Self.timedKey)
            CATransaction.commit()
        }

        var presentedContentOffset: LayoutPoint {
            guard scrollView.layer.animation(forKey: Self.timedKey) != nil,
                let bounds = scrollView.layer.presentation()?.bounds
            else { return contentOffset }

            return LayoutPoint(x: Double(bounds.origin.x), y: Double(bounds.origin.y))
        }

        /// Ends a timed animation where it is on screen.
        private func stopTimedAnimation() {
            guard scrollView.layer.animation(forKey: Self.timedKey) != nil else { return }

            let presented = presentedContentOffset
            timedRevision &+= 1
            scrollView.layer.removeAnimation(forKey: Self.timedKey)
            scrollView.setContentOffset(CGPoint(x: presented.x, y: presented.y), animated: false)
        }

        private func resolvePendingAnimatedCompletion(finished: Bool) {
            guard let pending = pendingAnimatedCompletion else { return }

            pendingAnimatedCompletion = nil
            isAnimatingProgrammatically = false
            pending(finished)
        }

        private func reportOffset(phase: ScrollPhase) {
            delegate?.scrollBacking(for: nodeID, didChangeOffset: contentOffset, phase: phase)
        }

        private func currentPhase() -> ScrollPhase {
            if scrollView.isDragging { return .dragging }
            if scrollView.isDecelerating { return .decelerating }
            return isAnimatingProgrammatically ? .settling : .idle
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportOffset(phase: currentPhase())
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // §7 scenario 2: user input interrupts a programmatic command in flight.
            resolvePendingAnimatedCompletion(finished: false)
            stopTimedAnimation()
            reportOffset(phase: .dragging)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            reportOffset(phase: decelerate ? .decelerating : .idle)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportOffset(phase: .idle)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            reportOffset(phase: .idle)
            resolvePendingAnimatedCompletion(finished: true)
        }
    }
#endif
