#if canImport(AppKit)
    import AppKit
    import LayoutCore

    extension NSView: LayoutElement {
        /// How the view measures inside a spec: by its own spec if it provides one, by
        /// `sizeThatFits` for controls (text fields, buttons), by its intrinsic content size
        /// if it has one, and not at all otherwise.
        ///
        /// Ownership: returns a value holding the view weakly for the pass. Isolation:
        /// MainActor. Errors: none. Cancellation: none.
        public var layoutContent: LeafContent? {
            if self is LayoutSpecProviding || self is NSControl {
                return .measured(ViewMeasurer(view: self))
            }

            let intrinsic = intrinsicContentSize
            if intrinsic.width == NSView.noIntrinsicMetric
                || intrinsic.height == NSView.noIntrinsicMetric
            {
                return nil
            }

            return .size(width: Double(intrinsic.width), height: Double(intrinsic.height))
        }

        /// Sets the view's frame. Layout coordinates grow downward; in a superview that is not
        /// flipped the position is mirrored vertically so the result looks the same.
        ///
        /// Ownership: mutates the view. Isolation: MainActor. Errors: none. Cancellation: none.
        public func applyLayoutFrame(_ frame: CGRect) {
            var frame = frame
            if let superview, !superview.isFlipped {
                let bounds = superview.bounds
                frame.origin.y = bounds.minY + bounds.maxY - frame.maxY
            }
            self.frame = frame
        }
    }

    extension LayoutSpecProviding where Self: NSView {
        /// Lays out `layoutSpec()` in the view's bounds. Call it from `layout()` of a class
        /// that cannot inherit from `LayoutNSView`.
        ///
        /// Ownership: sets frames of the spec's elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func applyLayoutSpec() {
            layoutSpec()?.apply(in: bounds, direction: layoutDirection, scale: layoutScale)
        }

        /// The size of `layoutSpec()` for `size`: a width of zero or of
        /// `.greatestFiniteMagnitude` means "no limit".
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public func layoutSpecSize(fitting size: CGSize) -> CGSize {
            guard let spec = layoutSpec() else { return .zero }

            let limited = size.width > 0 && size.width < CGFloat.greatestFiniteMagnitude
            return spec.measure(
                width: limited ? .definite(Double(size.width)) : .maxContent,
                direction: layoutDirection
            )
        }

        var layoutDirection: LayoutDirection {
            userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }

        var layoutScale: Double {
            Double(window?.backingScaleFactor ?? 1)
        }
    }

    /// A view that lays out its subviews with a spec: override `layoutSpec()` and nothing
    /// else. It is flipped (y grows downward, like the layout) and answers
    /// `intrinsicContentSize` from the spec.
    ///
    /// Ownership: owns its subviews like any view. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    open class LayoutNSView: NSView, LayoutSpecProviding {
        /// The layout of this view's subviews; `nil` lays out nothing.
        ///
        /// Ownership: returns a value borrowing the subviews. Isolation: MainActor.
        /// Errors: none. Cancellation: none.
        open func layoutSpec() -> LayoutSpec? { nil }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        open override var isFlipped: Bool { true }

        /// Ownership: sets subview frames. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        open override func layout() {
            super.layout()
            applyLayoutSpec()
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        open override var intrinsicContentSize: CGSize {
            guard layoutSpec() != nil else {
                return CGSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
            }

            return layoutSpecSize(fitting: .zero)
        }

        /// Tells the view that what `layoutSpec()` returns has changed.
        ///
        /// Ownership: schedules work on the view. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func setNeedsLayoutSpec() {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// Measures a view for the layout engine on the main thread; see the UIKit counterpart.
    @MainActor
    final class ViewMeasurer: ContentMeasurer {
        private weak var view: NSView?

        init(view: NSView) {
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
                return Double(
                    spec?.measure(width: limit == nil ? .maxContent : .minContent).width ?? 0
                )
            }

            return max(0, Double(fitting(view, width: limit).width))
        }

        private func height(width: Double) -> Double {
            guard let view else { return 0 }

            if let provider = view as? LayoutSpecProviding {
                return Double(provider.layoutSpec()?.measure(width: .definite(width)).height ?? 0)
            }

            return max(0, Double(fitting(view, width: width).height))
        }

        private func fitting(_ view: NSView, width: Double?) -> CGSize {
            let size = CGSize(
                width: width.map { CGFloat($0) } ?? CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            if let control = view as? NSControl { return control.sizeThatFits(size) }

            return view.intrinsicContentSize
        }
    }
#endif
