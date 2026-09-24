// Modifiers return a new spec; the original is untouched. Item modifiers (`flex`, `size`,
// `margin`, `alignSelf`, …) describe the place of the item in its parent. Container modifiers
// (`gap`, `justifyContent`, `alignItems`, …) describe how a container lays out its items.

extension LayoutSpecConvertible {
    private func modified(_ change: (inout FlexStyle) -> Void) -> LayoutSpec {
        var spec = asLayoutSpec
        change(&spec.style)
        return spec
    }

    // MARK: Item

    /// How the item grows and shrinks along its container's main axis, and its flex basis.
    /// Arguments left `nil` keep their current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func flex(grow: Double? = nil, shrink: Double? = nil, basis: Length? = nil) -> LayoutSpec
    {
        modified { style in
            if let grow { style.grow = grow }
            if let shrink { style.shrink = shrink }
            if let basis { style.basis = basis }
        }
    }

    /// Cross-axis alignment of this item, overriding the container's `alignItems`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func alignSelf(_ alignment: AlignSelf) -> LayoutSpec {
        modified { $0.alignSelf = alignment }
    }

    /// Layout order among siblings; lower first, document order breaks ties.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func order(_ order: Int) -> LayoutSpec {
        modified { $0.order = order }
    }

    /// A square size.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func size(_ side: Double) -> LayoutSpec {
        modified { style in
            style.width = .points(side)
            style.height = .points(side)
        }
    }

    /// Width and height; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func size(width: Length? = nil, height: Length? = nil) -> LayoutSpec {
        modified { style in
            if let width { style.width = width }
            if let height { style.height = height }
        }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func width(_ width: Length) -> LayoutSpec {
        modified { $0.width = width }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func height(_ height: Length) -> LayoutSpec {
        modified { $0.height = height }
    }

    /// Minimum and maximum sizes; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func limits(
        minWidth: Length? = nil,
        maxWidth: Length? = nil,
        minHeight: Length? = nil,
        maxHeight: Length? = nil
    ) -> LayoutSpec {
        modified { style in
            if let minWidth { style.minWidth = minWidth }
            if let maxWidth { style.maxWidth = maxWidth }
            if let minHeight { style.minHeight = minHeight }
            if let maxHeight { style.maxHeight = maxHeight }
        }
    }

    /// Width divided by height.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func aspectRatio(_ ratio: Double) -> LayoutSpec {
        modified { $0.aspectRatio = ratio }
    }

    /// The same margin on every side; `.auto` absorbs free space.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(_ all: Margin) -> LayoutSpec {
        modified { $0.margin = Edges(all: all) }
    }

    /// Margins per side; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(
        top: Margin? = nil,
        leading: Margin? = nil,
        bottom: Margin? = nil,
        trailing: Margin? = nil
    ) -> LayoutSpec {
        modified { style in
            if let top { style.margin.top = top }
            if let leading { style.margin.leading = leading }
            if let bottom { style.margin.bottom = bottom }
            if let trailing { style.margin.trailing = trailing }
        }
    }

    /// Margins along each axis; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func margin(horizontal: Margin? = nil, vertical: Margin? = nil) -> LayoutSpec {
        margin(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
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
        trailing: Double? = nil
    ) -> LayoutSpec {
        modified { style in
            style.position = .absolute
            style.insets = Edges(top: top, leading: leading, bottom: bottom, trailing: trailing)
        }
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
    public func padding(_ all: Double) -> LayoutSpec {
        padding(top: all, leading: all, bottom: all, trailing: all)
    }

    /// Padding along each axis; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(horizontal: Double? = nil, vertical: Double? = nil) -> LayoutSpec {
        padding(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    /// Padding per side; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func padding(
        top: Double? = nil,
        leading: Double? = nil,
        bottom: Double? = nil,
        trailing: Double? = nil
    ) -> LayoutSpec {
        var spec = asLayoutSpec
        if spec.isElement {
            spec = LayoutSpec(insetting: spec)
        }

        if let top { spec.style.padding.top = top }
        if let leading { spec.style.padding.leading = leading }
        if let bottom { spec.style.padding.bottom = bottom }
        if let trailing { spec.style.padding.trailing = trailing }
        return spec
    }

    // MARK: Container

    /// The same gap between rows and between columns.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func gap(_ gap: Double) -> LayoutSpec {
        modified { style in
            style.rowGap = gap
            style.columnGap = gap
        }
    }

    /// Gaps between rows and between columns; `nil` keeps the current value.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func gap(row: Double? = nil, column: Double? = nil) -> LayoutSpec {
        modified { style in
            if let row { style.rowGap = row }
            if let column { style.columnGap = column }
        }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func justifyContent(_ value: JustifyContent) -> LayoutSpec {
        modified { $0.justifyContent = value }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func alignItems(_ value: AlignItems) -> LayoutSpec {
        modified { $0.alignItems = value }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func alignContent(_ value: AlignContent) -> LayoutSpec {
        modified { $0.alignContent = value }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public func wrap(_ value: FlexWrap = .wrap) -> LayoutSpec {
        modified { $0.wrap = value }
    }
}

extension LayoutSpec {
    /// A box around `inner` that only adds padding: its only item fills its content box
    /// unless the item sets its own size.
    init(insetting inner: LayoutSpec) {
        var item = inner
        if item.style.height == .auto && item.style.basis == .auto && item.style.grow == 0 {
            item.style.grow = 1
        }

        self.init(.column) { item }
    }
}
