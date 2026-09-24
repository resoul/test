#if canImport(AppKit)
    import AppKit

    import TrellisCore
    import TrellisRender

    /// `NativeScrollBacking` over a real `NSScrollView` (R07) — generalizes R06's prototype
    /// (`Tests/TrellisRenderTests/AppKitNativeScrollEmbeddingPrototypeTests.swift`, which wrapped
    /// a whole `TrellisHostView` as a `documentView`) to one `ScrollNode` anywhere in the tree:
    /// this creates its own `NSScrollView`/document view pair and adds the scroll view as a
    /// direct subview of the host view passed at creation, positioned by `LayerRenderer` at the
    /// node's committed frame in host-absolute coordinates.
    ///
    /// AppKit has no single delegate callback stream equivalent to `UIScrollViewDelegate` —
    /// phase is approximated from `NSScrollView.willStartLiveScrollNotification`/
    /// `didLiveScrollNotification`/`didEndLiveScrollNotification`: the whole live-scroll window
    /// (drag and any trackpad momentum after release) is reported as `.dragging`, not split into
    /// a separate `.decelerating` phase the way UIKit's delegate distinguishes — AppKit does not
    /// expose that distinction directly (R07's found-while-implementing note,
    /// `docs/validation/r07-scroll-node.md`).
    ///
    /// Ownership: owns its `NSScrollView`/document container and the installed content layer;
    /// the scroll view's `superview` retains it. Isolation: MainActor. Errors: none.
    /// Cancellation: an in-flight animated `scroll(to:...)` is cancelled by a later call to the
    /// same method or by the user starting a live scroll — both resolve the previous call's
    /// `completion` with `false`.
    @MainActor
    final class NSScrollViewBacking: NSObject, NativeScrollBacking {
        /// AppKit has no `isScrollEnabled` equivalent on `NSScrollView`. Gate wheel and
        /// trackpad events at the native view so `ScrollConfiguration.userInteractionEnabled`
        /// has the same meaning as UIKit while programmatic commands keep working.
        private final class TrellisScrollView: NSScrollView {
            var isTrellisUserInteractionEnabled = true

            override func scrollWheel(with event: NSEvent) {
                // A disabled scroll view acts as if it were not there: the event goes up the
                // responder chain to an enclosing scroll view (ADR 0037 §3 — a locked page
                // leaves the wheel to the outer scroll).
                guard isTrellisUserInteractionEnabled else {
                    nextResponder?.scrollWheel(with: event)
                    return
                }

                super.scrollWheel(with: event)
            }
        }

        /// A flipped, layer-backed document view — top-left origin, matching the shared
        /// renderer's coordinate convention (the same reasoning `TrellisHostView.isFlipped`
        /// documents for the host itself).
        private final class FlippedContentView: NSView {
            override var isFlipped: Bool { true }
        }

        private let nodeID: NodeID
        private weak var delegate: (any NativeScrollBackingDelegate)?
        private let scrollView = TrellisScrollView()
        private let documentContainer = FlippedContentView()
        private var hostContentOrigin = LayoutPoint(x: 0, y: 0)
        private var installedContentLayer: CALayer?
        private var pendingAnimatedCompletion: (@MainActor (Bool) -> Void)?
        private var isAnimatingProgrammatically = false
        private var animationRevision: UInt64 = 0
        private var isLiveScrolling = false
        private var observers: [NSObjectProtocol] = []

        /// Creates the backing's `NSScrollView`/document view and adds the scroll view as a
        /// subview of `superview` — called once per committed `ScrollNode`, from the
        /// `NativeScrollBackingFactory` closure `TrellisHostView.attach(root:)` supplies.
        ///
        /// Ownership: retains `nodeID`/`delegate` (weakly); `superview` retains the created
        /// scroll view. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        init(nodeID: NodeID, delegate: any NativeScrollBackingDelegate, superview: NSView) {
            self.nodeID = nodeID
            self.delegate = delegate
            super.init()
            scrollView.wantsLayer = true
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            documentContainer.wantsLayer = true
            scrollView.documentView = documentContainer
            superview.addSubview(scrollView)
            installLiveScrollObservers()
        }

        deinit {
            // Notification tokens are removed by `removeContentLayer()`, called by
            // `LayerRenderer` on every path that tears this backing down (R07's ownership
            // table) — `deinit` is `nonisolated` and cannot touch this MainActor-isolated
            // instance's own state to repeat that cleanup here.
        }

        var containerLayer: CALayer {
            scrollView.layer
                ?? {
                    // `wantsLayer = true` above guarantees a layer once the view is in a
                    // layer-backed hierarchy; this branch only matters before that first happens.
                    scrollView.wantsLayer = true
                    return scrollView.layer ?? CALayer()
                }()
        }

        func setFrame(_ frame: LayoutFrame, relativeTo parentContentOrigin: LayoutPoint?) {
            // `NSView.frame` is the source of truth AppKit's own mouse hit-testing reads;
            // setting it (not `scrollView.layer.bounds`/`.position` directly) keeps that
            // hit-testing correct and leaves the clip view's `bounds.origin` (the native
            // content offset) untouched (R07's found-while-implementing note,
            // `docs/validation/r07-scroll-node.md`). The host is flipped
            // (`TrellisHostView.isFlipped`), so `frame.origin` is already top-left in the
            // superview's own coordinate system — no manual flip conversion needed.
            scrollView.frame = NSRect(
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
            return NSScrollViewBacking(
                nodeID: nodeID,
                delegate: delegate,
                superview: documentContainer
            )
        }

        var viewportSize: MeasuredSize {
            let visible = scrollView.contentView.documentVisibleRect
            return MeasuredSize(width: Double(visible.width), height: Double(visible.height))
        }

        var contentOffset: LayoutPoint {
            get {
                let origin = scrollView.contentView.bounds.origin
                return LayoutPoint(x: Double(origin.x), y: Double(origin.y))
            }
            set {
                scrollView.contentView.scroll(to: NSPoint(x: newValue.x, y: newValue.y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        func setContentSize(_ size: MeasuredSize) {
            let resolved = NSSize(width: size.width, height: size.height)
            guard documentContainer.frame.size != resolved else { return }

            documentContainer.frame = NSRect(origin: documentContainer.frame.origin, size: resolved)
        }

        func setInsets(_ insets: DirectionalEdgeInsets) {
            let direction: LayoutDirection =
                scrollView.userInterfaceLayoutDirection == .rightToLeft
                ? .rightToLeft : .leftToRight
            let physical = insets.resolved(for: direction)
            let resolved = NSEdgeInsets(
                top: physical.top,
                left: physical.left,
                bottom: physical.bottom,
                right: physical.right
            )
            guard !NSEdgeInsetsEqual(scrollView.contentInsets, resolved) else { return }

            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = resolved
        }

        func apply(configuration: ScrollConfiguration) {
            scrollView.isTrellisUserInteractionEnabled = configuration.userInteractionEnabled
            scrollView.hasVerticalScroller =
                configuration.indicators == .automatic && configuration.axis != .horizontal
            scrollView.hasHorizontalScroller =
                configuration.indicators == .automatic && configuration.axis != .vertical
            let elasticity: NSScrollView.Elasticity =
                switch configuration.bounce {
                case .automatic: .automatic
                case .always: .allowed
                case .never: .none
                }
            scrollView.verticalScrollElasticity = elasticity
            scrollView.horizontalScrollElasticity = elasticity
        }

        func installContentLayer(_ layer: CALayer) {
            installedContentLayer = layer
            documentContainer.layer?.addSublayer(layer)
        }

        func removeContentLayer() {
            installedContentLayer?.removeFromSuperlayer()
            installedContentLayer = nil
            let center = NotificationCenter.default
            for observer in observers { center.removeObserver(observer) }
            observers.removeAll()
        }

        func dispose() {
            delegate = nil
            removeContentLayer()
            stopProgrammaticAnimation()
            scrollView.isTrellisUserInteractionEnabled = false
            scrollView.removeFromSuperview()
        }

        func scroll(
            to offset: LayoutPoint,
            animated: Bool,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            stopProgrammaticAnimation()
            let revision = animationRevision
            let target = NSPoint(x: offset.x, y: offset.y)
            guard animated else {
                scrollView.contentView.scroll(to: target)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                reportOffset(phase: .programmatic)
                completion(true)
                return
            }

            isAnimatingProgrammatically = true
            pendingAnimatedCompletion = completion
            reportOffset(phase: .settling)
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.25
                    self.scrollView.contentView.animator().setBoundsOrigin(target)
                },
                completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.animationRevision == revision else { return }

                        self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                        self.reportOffset(phase: .idle)
                        self.resolvePendingAnimatedCompletion(finished: true)
                    }
                }
            )
        }

        func scroll(
            to offset: LayoutPoint,
            animation: TrellisCore.Animation,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            stopProgrammaticAnimation()
            let revision = animationRevision
            let target = NSPoint(x: offset.x, y: offset.y)
            guard animation.duration > .zero else {
                scroll(to: offset, animated: false, completion: completion)
                return
            }

            isAnimatingProgrammatically = true
            pendingAnimatedCompletion = completion
            reportOffset(phase: .settling)
            let timing = makeAnimation(keyPath: "bounds", timing: animation)
            NSAnimationContext.runAnimationGroup(
                { context in
                    // AppKit animates the clip view's bounds frame by frame; a spring maps to
                    // its settling duration with the ease-out curve (no spring timing here).
                    context.duration = timing.duration
                    context.timingFunction =
                        timing.timingFunction ?? CAMediaTimingFunction(name: .easeOut)
                    self.scrollView.contentView.animator().setBoundsOrigin(target)
                },
                completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.animationRevision == revision else { return }

                        self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                        self.reportOffset(phase: .idle)
                        self.resolvePendingAnimatedCompletion(finished: true)
                    }
                }
            )
        }

        private func stopProgrammaticAnimation() {
            animationRevision &+= 1
            if isAnimatingProgrammatically {
                let origin = scrollView.contentView.bounds.origin
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    scrollView.contentView.animator().setBoundsOrigin(origin)
                }
            }
            resolvePendingAnimatedCompletion(finished: false)
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

        private func installLiveScrollObservers() {
            let center = NotificationCenter.default
            scrollView.contentView.postsBoundsChangedNotifications = true
            observers.append(
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.reportOffset(
                            phase: self.isLiveScrolling
                                ? .dragging
                                : (self.isAnimatingProgrammatically ? .settling : .idle)
                        )
                    }
                }
            )
            // Notification callbacks arrive on the main thread (AppKit posts these
            // synchronously from live-scroll event handling, never off-main) — wrapped in
            // `MainActor.assumeIsolated` so this MainActor-isolated backing can mutate its own
            // state from `NotificationCenter`'s nonisolated closure type.
            observers.append(
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }

                        self.isLiveScrolling = true
                        // §7 scenario 2: user input interrupts a programmatic command in flight.
                        self.stopProgrammaticAnimation()
                        self.reportOffset(phase: .dragging)
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: scrollView,
                    queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reportOffset(phase: .dragging)
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView,
                    queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }

                        self.isLiveScrolling = false
                        self.reportOffset(phase: .idle)
                    }
                }
            )
        }
    }
#endif
