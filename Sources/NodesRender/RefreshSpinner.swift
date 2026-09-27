#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import ThemeCore
    import QuartzCore

    /// The refresh indicator a scroll uses by default: an arc that grows as the scroll is
    /// pulled, closed to a ring's three quarters when letting go refreshes, and turning while
    /// the refresh goes on.
    ///
    ///     feed.onRefresh = { await model.reload() }
    ///     feed.refreshIndicator = RefreshSpinner()
    ///
    /// Ownership: the scroll owns it as its indicator. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public final class RefreshSpinner: Node, LayerDrawing, RefreshIndicator {
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        /// The ring's color; `nil` for the theme's secondary text color.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var color: Color? {
            didSet { if color != oldValue { update() } }
        }

        /// The color the ring is drawn in.
        private(set) var shownColor = Color.black

        /// How much of the ring shows: the pull, up to three quarters.
        private(set) var sweep = 0.0
        private var revision: UInt64 = 0

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(color: Color? = nil) {
            self.color = color
            super.init()
            accessibility.label = "Refreshing"
            accessibility.isElement = false
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public func showRefresh(pull: Double, isRefreshing: Bool) {
            let sweep = isRefreshing ? 0.75 : 0.75 * pull
            if sweep != self.sweep {
                self.sweep = sweep
                redraw()
            }
            appearance.spin = isRefreshing ? 1 : 0
            // Assistive technologies hear of it only while it refreshes.
            accessibility.isElement = isRefreshing
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public override var layoutContent: LeafContent? {
            .size(LayoutSize(width: 0, height: 0))
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var drawingRevision: UInt64 { revision }

        /// Ownership: draws into `context`. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func draw(in context: CGContext, size: CGSize) {
            guard sweep > 0 else { return }

            let radius: CGFloat = 10
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // From the top, clockwise on the screen: Core Graphics' y goes up here.
            let start = CGFloat.pi / 2
            context.setStrokeColor(
                CGColor(
                    red: CGFloat(shownColor.red),
                    green: CGFloat(shownColor.green),
                    blue: CGFloat(shownColor.blue),
                    alpha: CGFloat(shownColor.alpha)
                )
            )
            context.setLineWidth(2.5)
            context.setLineCap(.round)
            context.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: start - CGFloat(sweep) * 2 * .pi,
                clockwise: true
            )
            context.strokePath()
        }

        /// Follows the theme when the ring has no color of its own.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func update() {
            let now = color ?? theme.color(.secondaryText)
            guard now != shownColor else { return }

            shownColor = now
            redraw()
        }

        private func redraw() {
            revision &+= 1
            host?.setNeedsRender()
        }
    }
#endif
