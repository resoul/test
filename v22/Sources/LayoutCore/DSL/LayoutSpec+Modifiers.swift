// Modifiers return a new spec; the original is untouched. Item modifiers (`flex`, `size`,
// `margin`, `alignSelf`, …) describe the place of the item in its parent. Container modifiers
// (`gap`, `justifyContent`, `alignItems`, …) describe how a container lays out its items.
//
// Every modifier takes `from:`: without it the change always applies; with it, only while
// the width the parent gives this item reaches that value. Changes apply in the order they
// are written, so `.gap(8).gap(16, from: .md)` is 8, and 16 from `.md` on.
//
// Every value is optional, and `nil` leaves the spec exactly as it was: a value that exists
// only in some states is written in place (`.padding(isCompact ? nil : 16)`) instead of
// around the modifier.

extension LayoutSpecConvertible {
    func patched(
        from: BreakpointWidth?,
        _ change: @escaping @MainActor (inout FlexStyle, SpacingScale) -> Void
    ) -> LayoutSpec {
        var spec = asLayoutSpec
        spec.patches.append(LayoutSpec.StylePatch(from: from, apply: change))
        return spec
    }

    // MARK: Item

    /// How the item grows and shrinks along its container's main axis, and its flex basis.
    /// Arguments left `nil` keep their current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func flex(
        grow: Double? = nil,
        shrink: Double? = nil,
        basis: Length? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        patched(from: from) { style, _ in
            if let grow { style.grow = grow }
            if let shrink { style.shrink = shrink }
            if let basis { style.basis = basis }
        }
    }

    /// Cross-axis alignment of this item, overriding the container's `alignItems`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func alignSelf(_ alignment: AlignSelf?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let alignment else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.alignSelf = alignment }
    }

    /// Layout order among siblings; lower first, document order breaks ties.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func order(_ order: Int?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let order else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.order = order }
    }

    /// A square size.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func size(_ side: Double?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let side else { return asLayoutSpec }

        return patched(from: from) { style, _ in
            style.width = .points(side)
            style.height = .points(side)
        }
    }

    /// Width and height; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func size(
        width: Length? = nil,
        height: Length? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        patched(from: from) { style, _ in
            if let width { style.width = width }
            if let height { style.height = height }
        }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func width(_ width: Length?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let width else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.width = width }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func height(_ height: Length?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let height else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.height = height }
    }

    /// Minimum and maximum sizes; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func limits(
        minWidth: Length? = nil,
        maxWidth: Length? = nil,
        minHeight: Length? = nil,
        maxHeight: Length? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        patched(from: from) { style, _ in
            if let minWidth { style.minWidth = minWidth }
            if let maxWidth { style.maxWidth = maxWidth }
            if let minHeight { style.minHeight = minHeight }
            if let maxHeight { style.maxHeight = maxHeight }
        }
    }

    /// Width divided by height.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func aspectRatio(_ ratio: Double?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let ratio else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.aspectRatio = ratio }
    }

    /// Takes the item out of the flow and pins it to its container's padding box. A side
    /// left `nil` is free; with neither inset on an axis, the item keeps the place it would
    /// have as the container's only item.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func absolute(
        top: Double? = nil,
        leading: Double? = nil,
        bottom: Double? = nil,
        trailing: Double? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        patched(from: from) { style, _ in
            style.position = .absolute
            style.insets = Edges(top: top, leading: leading, bottom: bottom, trailing: trailing)
        }
    }

    /// Keeps the element in its place in the layout, but while the scroll it is in moves,
    /// holds it within `top` points of the scroll's top edge (or of the other edges given)
    /// for as long as its container is in view: a section's header stays at the top while
    /// its section passes under it, and the next section pushes it out — CSS
    /// `position: sticky`. It is drawn over the other items of its container. Only an
    /// element sticks (a node); outside a scroll nothing moves. Following the scroll costs no
    /// layout pass.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func sticky(
        top: Double? = nil,
        leading: Double? = nil,
        bottom: Double? = nil,
        trailing: Double? = nil
    ) -> LayoutSpec {
        var spec = asLayoutSpec
        spec.stickyInsets = Edges(top: top, leading: leading, bottom: bottom, trailing: trailing)
        return spec
    }

    // MARK: Margin

    /// The same margin on every side; `.auto` absorbs free space.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(_ all: Margin?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let all else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.margin = Edges(all: all) }
    }

    /// The same margin on every side, from the spacing scale.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(_ all: Spacing?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let all else { return asLayoutSpec }

        return patched(from: from) { style, scale in
            style.margin = Edges(all: .points(scale.points(all)))
        }
    }

    /// Margins per side; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(
        top: Margin? = nil,
        leading: Margin? = nil,
        bottom: Margin? = nil,
        trailing: Margin? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        patched(from: from) { style, _ in
            if let top { style.margin.top = top }
            if let leading { style.margin.leading = leading }
            if let bottom { style.margin.bottom = bottom }
            if let trailing { style.margin.trailing = trailing }
        }
    }

    /// Margins per side from the spacing scale; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(
        top: Spacing? = nil,
        leading: Spacing? = nil,
        bottom: Spacing? = nil,
        trailing: Spacing? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        patched(from: from) { style, scale in
            if let top { style.margin.top = .points(scale.points(top)) }
            if let leading { style.margin.leading = .points(scale.points(leading)) }
            if let bottom { style.margin.bottom = .points(scale.points(bottom)) }
            if let trailing { style.margin.trailing = .points(scale.points(trailing)) }
        }
    }

    /// Margins along each axis; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(
        horizontal: Margin? = nil,
        vertical: Margin? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        margin(
            top: vertical,
            leading: horizontal,
            bottom: vertical,
            trailing: horizontal,
            from: from
        )
    }

    // MARK: Padding

    /// Space inside the box, on every side.
    ///
    /// On a container, padding insets its items. On an element, padding is space around the
    /// element, and it applies to what came before it: `avatar.size(48).padding(8)` keeps a
    /// 48-point avatar in a 64-point slot, while `avatar.padding(8).size(48)` makes the slot
    /// 48 points and the avatar 32.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(_ all: Double?, from: BreakpointWidth? = nil) -> LayoutSpec {
        padding(top: all, leading: all, bottom: all, trailing: all, from: from)
    }

    /// Padding on every side from the spacing scale.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(_ all: Spacing?, from: BreakpointWidth? = nil) -> LayoutSpec {
        padding(top: all, leading: all, bottom: all, trailing: all, from: from)
    }

    /// Padding along each axis; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(
        horizontal: Double? = nil,
        vertical: Double? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        padding(
            top: vertical,
            leading: horizontal,
            bottom: vertical,
            trailing: horizontal,
            from: from
        )
    }

    /// Padding along each axis from the spacing scale; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(
        horizontal: Spacing? = nil,
        vertical: Spacing? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        padding(
            top: vertical,
            leading: horizontal,
            bottom: vertical,
            trailing: horizontal,
            from: from
        )
    }

    /// Padding per side; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(
        top: Double? = nil,
        leading: Double? = nil,
        bottom: Double? = nil,
        trailing: Double? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        padding(
            top: top.map(Spacing.points),
            leading: leading.map(Spacing.points),
            bottom: bottom.map(Spacing.points),
            trailing: trailing.map(Spacing.points),
            from: from
        )
    }

    /// Padding per side from the spacing scale; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(
        top: Spacing? = nil,
        leading: Spacing? = nil,
        bottom: Spacing? = nil,
        trailing: Spacing? = nil,
        from: BreakpointWidth? = nil
    ) -> LayoutSpec {
        // With no side given there is nothing to add; wrapping an element anyway would
        // move the modifiers written before into the inset box and change its layout.
        guard top != nil || leading != nil || bottom != nil || trailing != nil else {
            return asLayoutSpec
        }

        var spec = asLayoutSpec
        if spec.isElement {
            spec = LayoutSpec(insetting: spec)
        }

        return spec.patched(from: from) { style, scale in
            if let top { style.padding.top = scale.points(top) }
            if let leading { style.padding.leading = scale.points(leading) }
            if let bottom { style.padding.bottom = scale.points(bottom) }
            if let trailing { style.padding.trailing = scale.points(trailing) }
        }
    }

    // MARK: Visibility

    /// Takes the item out of the layout: it gets no space and no frame, and its elements are
    /// hidden. With `false` it is laid out and its elements are shown. Keep the modifier with
    /// a condition rather than removing it, so the elements are shown again.
    ///
    /// This is CSS `display: none` and what `isHidden` does in a `UIStackView`. SwiftUI's
    /// `.hidden()` means the opposite — it keeps the space; here that is `invisible(_:)`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func hidden(_ isHidden: Bool = true, from: BreakpointWidth? = nil) -> LayoutSpec {
        var spec =
            isHidden ? patched(from: from) { style, _ in style.display = .none } : asLayoutSpec
        spec.managesVisibility = true
        return spec
    }

    /// Keeps the item's space in the layout but hides its elements — for content that comes
    /// and goes without the layout jumping (a spinner in a button, room for a badge). CSS
    /// `visibility: hidden`, and what SwiftUI's `.hidden()` does.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func invisible(_ isInvisible: Bool = true) -> LayoutSpec {
        var spec = asLayoutSpec
        spec.managesVisibility = true
        spec.isInvisible = isInvisible
        return spec
    }

    // MARK: Conditions

    /// Applies `transform` when `condition` holds and leaves the item as it is otherwise —
    /// for several modifiers that come and go together. A single value is simpler as a value
    /// (`.padding(isCompact ? 8 : 16)`). The spec is rebuilt on every pass and the element
    /// keeps its identity, so switching the condition only changes the item's place.
    ///
    ///     title.if(isHighlighted) { $0.padding(16).alignSelf(.center) }
    ///
    /// Ownership: returns a value; `transform` is not kept. Isolation: MainActor.
    /// Errors: none. Cancellation: none.
    public func `if`(
        _ condition: Bool,
        _ transform: (LayoutSpec) -> LayoutSpec
    ) -> LayoutSpec {
        condition ? transform(asLayoutSpec) : asLayoutSpec
    }

    // MARK: Container

    /// Takes a container with no items out of the layout, padding and all, as CSS
    /// `:empty { display: none }` does. Items are counted as written: an `if` that is false
    /// or a `nil` element adds none, a hidden item still counts. Has no effect on an element.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func collapsesWhenEmpty() -> LayoutSpec {
        let spec = asLayoutSpec
        guard case let .container(items) = spec.content, items.isEmpty else { return spec }

        return spec.patched(from: nil) { style, _ in style.display = .none }
    }

    /// The main axis of a container.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func direction(_ direction: FlexDirection?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let direction else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.direction = direction }
    }

    /// The same gap between rows and between columns.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func gap(_ gap: Double?, from: BreakpointWidth? = nil) -> LayoutSpec {
        self.gap(gap.map(Spacing.points), from: from)
    }

    /// The same gap between rows and between columns, from the spacing scale.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func gap(_ gap: Spacing?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let gap else { return asLayoutSpec }

        return patched(from: from) { style, scale in
            style.rowGap = scale.points(gap)
            style.columnGap = scale.points(gap)
        }
    }

    /// Gaps between rows and between columns; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func gap(row: Double? = nil, column: Double? = nil, from: BreakpointWidth? = nil)
        -> LayoutSpec
    {
        gap(row: row.map(Spacing.points), column: column.map(Spacing.points), from: from)
    }

    /// Gaps between rows and between columns from the spacing scale; `nil` keeps the
    /// current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func gap(row: Spacing? = nil, column: Spacing? = nil, from: BreakpointWidth? = nil)
        -> LayoutSpec
    {
        patched(from: from) { style, scale in
            if let row { style.rowGap = scale.points(row) }
            if let column { style.columnGap = scale.points(column) }
        }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func justifyContent(_ value: JustifyContent?, from: BreakpointWidth? = nil)
        -> LayoutSpec
    {
        guard let value else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.justifyContent = value }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func alignItems(_ value: AlignItems?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let value else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.alignItems = value }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func alignContent(_ value: AlignContent?, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let value else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.alignContent = value }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func wrap(_ value: FlexWrap? = .wrap, from: BreakpointWidth? = nil) -> LayoutSpec {
        guard let value else { return asLayoutSpec }

        return patched(from: from) { style, _ in style.wrap = value }
    }
}

extension LayoutSpec {
    /// A box around `inner` that only adds padding: its only item fills its content box
    /// unless the item sets its own height, basis or grow.
    init(insetting inner: LayoutSpec) {
        let item = inner.patched(from: nil) { style, _ in
            if style.height == .auto && style.basis == .auto && style.grow == 0 {
                style.grow = 1
            }
        }
        self.init(.column) { item }
    }
}
