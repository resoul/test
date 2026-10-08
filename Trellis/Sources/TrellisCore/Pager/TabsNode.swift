import Foundation

/// Colors and metrics of a `TabsNode`.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TabsAppearance: Sendable, Hashable {
    /// Title color of unselected tabs.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var titleColor: ThemeColor

    /// Title color of the selected tab.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var selectedTitleColor: ThemeColor

    /// Indicator color.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var indicatorColor: ThemeColor

    /// Indicator height in points.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var indicatorHeight: Double

    /// Title point size.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var titleSize: Double

    /// Height of the bar.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var height: Double

    /// Creates an appearance.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        titleColor: ThemeColor = ThemeColor(red: 0.55, green: 0.58, blue: 0.64),
        selectedTitleColor: ThemeColor = ThemeColor(red: 0.95, green: 0.96, blue: 0.98),
        indicatorColor: ThemeColor = ThemeColor(red: 0.35, green: 0.6, blue: 1),
        indicatorHeight: Double = 2,
        titleSize: Double = 15,
        height: Double = 44
    ) {
        self.titleColor = titleColor
        self.selectedTitleColor = selectedTitleColor
        self.indicatorColor = indicatorColor
        self.indicatorHeight = indicatorHeight
        self.titleSize = titleSize
        self.height = height
    }
}

/// Segmented switcher of a `PagerNode` (P6.5): one equal-width button per page and an
/// indicator. The indicator follows the pager's `progress` — with the finger during a drag and
/// with the same animation as the pages after release — so there is one model and no separate
/// animation (R13). A tap, the remote's select, Return/Space and the accessibility activate
/// action on a tab select its page; buttons are focusable and carry the selected state.
///
/// Ownership: retains the pager; the pager references this node weakly. Isolation:
/// MainActor. Errors: none. Cancellation: `dispose()` stops observing.
@MainActor
public final class TabsNode<ID: Hashable & Sendable>: Node, HostedContainer {
    /// The pager this bar switches.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let pager: PagerNode<ID>

    /// Colors and metrics; assigning rebuilds the buttons.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var tabsAppearance: TabsAppearance {
        didSet { if tabsAppearance != oldValue { rebuild() } }
    }

    private let row = Node()
    private let indicator = Node()
    private var buttons: [(id: ID, button: ControlNode, title: TextNode)] = []
    private var shown: PagerProgress<ID>?

    /// Creates a bar for `pager`.
    ///
    /// Ownership: retains `pager`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(
        pager: PagerNode<ID>,
        appearance: TabsAppearance = TabsAppearance(),
        style: LayoutStyle = LayoutStyle()
    ) {
        self.pager = pager
        self.tabsAppearance = appearance
        var barStyle = style
        if barStyle.height == .auto {
            barStyle.height = .points(appearance.height)
        }
        barStyle.flexShrink = 0
        super.init(style: barStyle)
        row.style {
            $0.flexDirection = .row
            $0.flexGrow = 1
            $0.alignItems = .stretch
        }
        indicator.style {
            $0.positionType = .absolute
            $0.offsets = DirectionalEdgeOffsets(leading: 0, bottom: 0)
            $0.height = .points(appearance.indicatorHeight)
            $0.width = .points(0)
        }
        addSubnode(row)
        addSubnode(indicator)
        pager.addObserver(
            PagerObservation(
                owner: self,
                tabsChanged: { [weak self] in self?.rebuild() },
                progressChanged: { [weak self] progress, animation in
                    self?.show(progress, animation: animation)
                }
            )
        )
        rebuild()
    }

    /// The button of page `id`, or `nil`.
    ///
    /// Ownership: the bar keeps owning it. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public func button(for id: ID) -> ControlNode? {
        buttons.first { $0.id == id }?.button
    }

    // MARK: HostedContainer

    /// Nothing to bind.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func hostDidAttach(_ host: any ContainerHost) {}

    /// Places the indicator once button frames are known or changed.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func hostDidCommit(_ commit: ContainerCommit) {
        placeIndicator(for: shown ?? pager.progress)
    }

    /// Nothing to release.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func hostDidDetach() {}

    // MARK: Private

    private func rebuild() {
        for entry in buttons {
            entry.button.dispose()
        }
        buttons = []
        indicator.appearance.background = .color(tabsAppearance.indicatorColor)
        indicator.style.height = .points(tabsAppearance.indicatorHeight)
        for tab in pager.tabs {
            let button = ControlNode()
            button.style {
                $0.flexGrow = 1
                $0.flexBasis = .points(0)
                $0.justifyContent = .center
                $0.alignItems = .stretch
            }
            var titleStyle = TextStyle(
                pointSize: tabsAppearance.titleSize,
                weight: .semibold,
                color: tabsAppearance.titleColor
            )
            titleStyle.alignment = .center
            let title = TextNode(text: tab.title, textStyle: titleStyle)
            // The title spans the button and centers its text: a title measured to its exact
            // width loses a fraction of a point to pixel rounding before raster and truncates
            // (defect #48).
            title.style.width = .fraction(1)
            button.addSubnode(title)
            button.accessibility.label = tab.title
            button.accessibility.role = .button
            button.accessibility.identifier = "tab-\(tab.id)"
            let id = tab.id
            button.activation = { [weak self] in
                self?.pager.select(id)
            }
            row.addSubnode(button)
            buttons.append((id, button, title))
        }
        shown = nil
        show(pager.progress, animation: .none)
    }

    private func show(_ progress: PagerProgress<ID>, animation: Animation) {
        shown = progress
        animate(animation) {
            placeIndicator(for: progress)
            let selected = progress.settled ?? progress.from
            for entry in buttons {
                let isSelected = entry.id == selected
                entry.button.accessibility.isSelected = isSelected
                var style = entry.title.textStyle
                style.color =
                    isSelected ? tabsAppearance.selectedTitleColor : tabsAppearance.titleColor
                entry.title.textStyle = style
            }
        }
    }

    /// Interpolates the indicator between the `from` and `to` buttons' committed frames.
    private func placeIndicator(for progress: PagerProgress<ID>) {
        guard let bar = calculatedFrame,
            let fromFrame = frame(of: progress.from),
            let toFrame = frame(of: progress.to ?? progress.from)
        else { return }

        let fraction = progress.fraction
        let x = fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x) * fraction
        let width = fromFrame.width + (toFrame.width - fromFrame.width) * fraction
        let physicalLeft = x - bar.origin.x
        let leading =
            environment.layoutDirection == .rightToLeft
            ? bar.width - physicalLeft - width : physicalLeft
        indicator.style.offsets = DirectionalEdgeOffsets(leading: leading, bottom: 0)
        indicator.style.width = .points(width)
    }

    private func frame(of id: ID?) -> LayoutFrame? {
        guard let id else { return nil }

        return buttons.first { $0.id == id }?.button.calculatedFrame
    }
}
