#if canImport(UIKit)
    import LayoutCore
    import UIKit

    extension UIView: LayoutElement {
        /// How the view measures inside a spec: by its own spec if it provides one, by
        /// `sizeThatFits` if it has intrinsic content (labels, images, buttons), and not at
        /// all otherwise — a plain view's size then comes only from the spec.
        ///
        /// Ownership: returns a value holding the view weakly for the pass. Isolation:
        /// MainActor. Errors: none. Cancellation: none.
        public var layoutContent: LeafContent? {
            if self is LayoutSpecProviding { return .measured(ViewMeasurer(view: self)) }

            let intrinsic = intrinsicContentSize
            if intrinsic.width == UIView.noIntrinsicMetric
                && intrinsic.height == UIView.noIntrinsicMetric
            {
                return nil
            }

            return .measured(ViewMeasurer(view: self))
        }

        /// Sets the view's size and position without touching its transform.
        ///
        /// Ownership: mutates the view. Isolation: MainActor. Errors: none. Cancellation: none.
        public func applyLayoutFrame(_ frame: LayoutRect) {
            let frame = CGRect(frame)
            bounds.size = frame.size
            center = CGPoint(x: frame.midX, y: frame.midY)
        }

        /// Shows or hides the view for `hidden`, `invisible` and `Breakpoint`.
        ///
        /// Ownership: mutates the view. Isolation: MainActor. Errors: none. Cancellation: none.
        public func applyLayoutVisibility(_ isVisible: Bool) {
            isHidden = !isVisible
        }
    }

    extension LayoutSpecProviding where Self: UIView {
        /// Lays out `layoutSpec()` in the view's bounds. Call it from `layoutSubviews` of a
        /// class that cannot inherit from `LayoutView` (cells, controls, third-party views).
        ///
        /// Ownership: sets frames of the spec's elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func applyLayoutSpec() {
            layoutSpec()?.apply(
                in: LayoutRect(bounds),
                direction: layoutDirection,
                scale: layoutScale,
                spacing: layoutSpacing
            )
        }

        /// The size of `layoutSpec()` for `size`: a width of zero or of
        /// `.greatestFiniteMagnitude` means "no limit". Use it in `sizeThatFits`.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public func layoutSpecSize(fitting size: CGSize) -> CGSize {
            guard let spec = layoutSpec() else { return .zero }

            let limited = size.width > 0 && size.width < CGFloat.greatestFiniteMagnitude
            let measured = spec.measure(
                width: limited ? .definite(Double(size.width)) : .maxContent,
                direction: layoutDirection,
                spacing: layoutSpacing
            )
            return CGSize(measured)
        }

        var layoutDirection: LayoutDirection {
            effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }

        var layoutScale: Double {
            let scale = Double(traitCollection.displayScale)
            return scale > 0 ? scale : 1
        }
    }

    /// A view that lays out its subviews with a spec: override `layoutSpec()` and nothing
    /// else. It also answers `sizeThatFits` and `intrinsicContentSize` from the spec, so it
    /// sizes itself in Auto Layout, in stack views and in self-sizing cells.
    ///
    /// Ownership: owns its subviews like any view. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    open class LayoutView: UIView, LayoutSpecProviding {
        /// The layout of this view's subviews; `nil` lays out nothing.
        ///
        /// Ownership: returns a value borrowing the subviews. Isolation: MainActor.
        /// Errors: none. Cancellation: none.
        open func layoutSpec() -> LayoutSpec? { nil }

        /// Ownership: sets subview frames. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        open override func layoutSubviews() {
            super.layoutSubviews()
            applyLayoutSpec()
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        open override func sizeThatFits(_ size: CGSize) -> CGSize {
            layoutSpecSize(fitting: size)
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        open override var intrinsicContentSize: CGSize {
            guard layoutSpec() != nil else {
                return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
            }

            return layoutSpecSize(fitting: .zero)
        }

        /// Tells the view that what `layoutSpec()` returns has changed: its size and its
        /// subview frames are computed again.
        ///
        /// Ownership: schedules work on the view. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func setNeedsLayoutSpec() {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// Measures a view for the layout engine. Layout of views runs synchronously on the main
    /// thread, so the engine calls this only there; the requirements are nonisolated only
    /// because the protocol serves background layout too, and `assumeIsolated` checks the
    /// thread at run time instead of trusting it.
    @MainActor
    final class ViewMeasurer: ContentMeasurer {
        private weak var view: UIView?

        init(view: UIView) {
            self.view = view
        }

        /// The narrowest width: what the view asks for when offered one point. Zero is not
        /// used, because views may read a zero width as "no limit".
        nonisolated func minContentWidth() -> Double {
            MainActor.assumeIsolated { min(width(limit: 1), width(limit: nil)) }
        }

        nonisolated func maxContentWidth() -> Double {
            MainActor.assumeIsolated { width(limit: nil) }
        }

        nonisolated func height(forWidth width: Double) -> Double {
            MainActor.assumeIsolated { height(width: width) }
        }

        private func width(limit: Double?) -> Double {
            guard let view else { return 0 }

            if let provider = view as? LayoutSpecProviding {
                let spec = provider.layoutSpec()
                let constraint = limit == nil ? AvailableSpace.maxContent : .minContent
                return Double(
                    spec?.measure(width: constraint, spacing: provider.layoutSpacing).width ?? 0
                )
            }

            let fitting = CGSize(
                width: limit.map { CGFloat($0) } ?? CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            return max(0, Double(view.sizeThatFits(fitting).width))
        }

        private func height(width: Double) -> Double {
            guard let view else { return 0 }

            if let provider = view as? LayoutSpecProviding {
                let spec = provider.layoutSpec()
                return Double(
                    spec?.measure(width: .definite(width), spacing: provider.layoutSpacing).height
                        ?? 0
                )
            }

            let fitting = CGSize(width: CGFloat(width), height: CGFloat.greatestFiniteMagnitude)
            return max(0, Double(view.sizeThatFits(fitting).height))
        }
    }

    extension CGRect {
        init(_ rect: LayoutRect) {
            self.init(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            )
        }
    }

    extension LayoutRect {
        init(_ rect: CGRect) {
            self.init(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.size.width),
                height: Double(rect.size.height)
            )
        }
    }

    extension CGSize {
        init(_ size: LayoutSize) {
            self.init(width: size.width, height: size.height)
        }
    }
#endif
