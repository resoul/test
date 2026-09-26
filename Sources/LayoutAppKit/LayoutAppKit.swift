// AppKit only where UIKit is not: Mac Catalyst imports both, but has no NSView — an app there
// is a UIKit app and uses the UIKit adapter, so this module is empty.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import os

    /// Where the adapter writes layout reports.
    private let layoutLog = Logger(subsystem: "Layout", category: "layout")

    @MainActor
    enum LayoutReportLog {
        /// Problems in a spec, and a trace the app asked for, go to the unified log while
        /// debugging; a pass without either stays quiet. `nil` outside `DEBUG`: nothing is
        /// reported.
        static var handler: (@MainActor (LayoutSpecReport) -> Void)? {
            #if DEBUG
                return { report in
                    guard report.hasProblems || !report.trace.isEmpty else { return }

                    for line in report.lines {
                        layoutLog.log("\(line, privacy: .public)")
                    }
                }
            #else
                return nil
            #endif
        }
    }

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
        public func applyLayoutFrame(_ frame: LayoutRect) {
            var frame = CGRect(frame)
            if let superview, !superview.isFlipped {
                let bounds = superview.bounds
                frame.origin.y = bounds.minY + bounds.maxY - frame.maxY
            }
            self.frame = frame
        }

        /// Shows or hides the view for `hidden`, `invisible` and `Breakpoint`.
        ///
        /// Ownership: mutates the view. Isolation: MainActor. Errors: none. Cancellation: none.
        public func applyLayoutVisibility(_ isVisible: Bool) {
            isHidden = !isVisible
        }
    }

    extension LayoutSpecProviding where Self: NSView {
        /// Lays out `layoutSpec()` in the view's bounds. Call it from `layout()` of a class
        /// that cannot inherit from `LayoutNSView`.
        ///
        /// In a `DEBUG` build problems of the spec go to the unified log (subsystem `Layout`,
        /// category `layout`).
        ///
        /// Ownership: sets frames of the spec's elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func applyLayoutSpec() {
            applyLayoutSpec(
                reporting: LayoutReportLog.handler.map {
                    LayoutSpecReporting(host: LayoutSpecReporting.hostName(for: self), handler: $0)
                }
            )
        }

        /// `applyLayoutSpec()` that hands what the pass found to `reporting` — `nil` reports
        /// nothing.
        ///
        /// Ownership: sets frames of the spec's elements. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func applyLayoutSpec(reporting: LayoutSpecReporting?) {
            layoutSpec()?.apply(
                in: LayoutRect(bounds),
                direction: layoutDirection,
                scale: layoutScale,
                spacing: layoutSpacing,
                reporting: reporting
            )
        }

        /// The size of `layoutSpec()` for `size`: a width of zero or of
        /// `.greatestFiniteMagnitude` means "no limit".
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

        /// Receives a report after every layout of the spec. In a `DEBUG` build it writes
        /// problems and a requested trace to the unified log (subsystem `Layout`, category
        /// `layout`); an app can replace it, and `nil` reports nothing.
        ///
        /// Ownership: the view keeps the closure; it must not keep the view. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var onLayoutReport: (@MainActor (LayoutSpecReport) -> Void)? = LayoutReportLog
            .handler

        /// What the engine records for the report: nothing when empty.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var traceAreas: Set<LayoutTraceArea> = []

        /// The elements traced, with the containers of their layouts; `nil` traces every one.
        ///
        /// Ownership: keeps the elements. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public var tracedElements: [any LayoutElement]?

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        open override var isFlipped: Bool { true }

        /// Ownership: sets subview frames. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        open override func layout() {
            super.layout()
            applyLayoutSpec(reporting: layoutReporting)
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        open override var intrinsicContentSize: CGSize {
            guard layoutSpec() != nil else {
                return CGSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
            }

            return layoutSpecSize(fitting: .zero)
        }

        private var layoutReporting: LayoutSpecReporting? {
            onLayoutReport.map {
                LayoutSpecReporting(
                    host: LayoutSpecReporting.hostName(for: self),
                    traceAreas: traceAreas,
                    tracedElements: tracedElements,
                    handler: $0
                )
            }
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
        /// Views are asked for their size on the main thread only.
        nonisolated var requiresMainThread: Bool { true }

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

            return max(0, Double(fitting(view, width: limit).width))
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
