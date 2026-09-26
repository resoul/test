import Foundation

/// A table row as the window sees it: the source item plus its section context and selection
/// (R12c, ADR 0034). Context is part of equality, so a row that becomes first/last in its
/// section or changes selection is updated in place.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TableRow<Item: Sendable & Equatable>: Sendable, Equatable {
    /// The source item.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let value: Item

    /// Section the row belongs to.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let sectionID: String

    /// The row opens its section; its cell shows the section header.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isFirstInSection: Bool

    /// The row closes its section; its cell draws no separator.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isLastInSection: Bool

    /// The row is selected.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isSelected: Bool

    /// Creates a row.
    ///
    /// Ownership: takes ownership of `value`. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        value: Item,
        sectionID: String,
        isFirstInSection: Bool,
        isLastInSection: Bool,
        isSelected: Bool
    ) {
        self.value = value
        self.sectionID = sectionID
        self.isFirstInSection = isFirstInSection
        self.isLastInSection = isLastInSection
        self.isSelected = isSelected
    }
}

/// How taps select rows.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TableSelectionMode: Sendable, Hashable {
    /// Taps report `onSelect` but keep no selection.
    case none
    /// A tap selects one row.
    case single
    /// A tap toggles a row.
    case multiple
}

/// Horizontal-only pan for row swipes: begins when the first movement past the threshold is
/// at least as horizontal as vertical, fails otherwise, so vertical scrolling keeps its gesture.
///
/// Ownership: the cell owns it. Isolation: MainActor. Errors: none. Cancellation: `reset()`
/// cancels a running swipe.
@MainActor
public final class RowSwipeRecognizer: GestureRecognizer {
    /// Recognition state.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var state: GestureState = .possible

    /// Called with the state and the horizontal translation in physical points.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var onSwipe: (@MainActor (GestureState, Double) -> Void)?

    private let threshold: Double
    private var down: PointerData?
    private var last = 0.0

    /// Creates a recognizer with a movement threshold.
    ///
    /// Ownership: the caller owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(threshold: Double = 10) {
        self.threshold = threshold
    }

    /// Consumes pointer events of one pointer.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func handle(_ event: Event) -> GestureResult {
        guard let data = event.pointer else { return .ignored }

        switch event.type {
        case .pointerDown where down == nil && state == .possible:
            down = data
            return .ignored
        case .pointerMove where down?.pointerID == data.pointerID:
            guard let down else { return .ignored }

            let dx = data.point.x - down.point.x
            let dy = data.point.y - down.point.y
            switch state {
            case .possible:
                guard max(abs(dx), abs(dy)) > threshold else { return .ignored }
                guard abs(dx) >= abs(dy) else {
                    state = .failed
                    return .failed
                }

                return step(.began, dx)
            case .began, .changed:
                return step(.changed, dx)
            default:
                return .ignored
            }
        case .pointerUp where down?.pointerID == data.pointerID:
            defer { down = nil }
            guard state == .began || state == .changed, let down else {
                state = .failed
                return .failed
            }

            return step(.ended, data.point.x - down.point.x)
        case .pointerCancel where down?.pointerID == data.pointerID:
            defer { down = nil }
            guard state == .began || state == .changed else {
                state = .cancelled
                return .cancelled
            }

            return step(.cancelled, last)
        default:
            return .ignored
        }
    }

    /// Returns to `.possible`, cancelling a running swipe.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: this is the
    /// cancellation point.
    public func reset() {
        if state == .began || state == .changed {
            _ = step(.cancelled, last)
        }
        down = nil
        last = 0
        state = .possible
    }

    private func step(_ next: GestureState, _ translation: Double) -> GestureResult {
        state = next
        last = translation
        onSwipe?(next, translation)
        switch next {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        default: return .cancelled
        }
    }
}

/// Appearance of table chrome.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TableAppearance: Sendable, Hashable {
    /// Row background; also hides the actions under an unrevealed row.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var rowBackground: ThemeColor

    /// Background of a selected row.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var selectedBackground: ThemeColor

    /// Separator color; `nil` hides separators.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var separatorColor: ThemeColor?

    /// Separator inset from the leading edge.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var separatorInset: Double

    /// Background of normal action buttons.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var actionBackground: ThemeColor

    /// Background of destructive action buttons.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var destructiveBackground: ThemeColor

    /// Creates an appearance.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        rowBackground: ThemeColor = ThemeColor(red: 1, green: 1, blue: 1),
        selectedBackground: ThemeColor = ThemeColor(red: 0.85, green: 0.9, blue: 1),
        separatorColor: ThemeColor? = ThemeColor(red: 0.8, green: 0.8, blue: 0.82),
        separatorInset: Double = 16,
        actionBackground: ThemeColor = ThemeColor(red: 0.45, green: 0.47, blue: 0.52),
        destructiveBackground: ThemeColor = ThemeColor(red: 0.9, green: 0.25, blue: 0.22)
    ) {
        self.rowBackground = rowBackground
        self.selectedBackground = selectedBackground
        self.separatorColor = separatorColor
        self.separatorInset = separatorInset
        self.actionBackground = actionBackground
        self.destructiveBackground = destructiveBackground
    }
}

/// Configuration and behaviour shared by all cells of one table. Internal: cells reach the
/// table only through this object, so they never retain it.
@MainActor
final class TableCellContext<ItemID: Hashable & Sendable> {
    var appearance = TableAppearance()
    var sectionHeader: (@MainActor (String) -> Node?)?
    var leadingActions: (@MainActor (ItemID) -> [RowAction<ItemID>])?
    var trailingActions: (@MainActor (ItemID) -> [RowAction<ItemID>])?
    var swipeActionsPolicy = SwipeActionsPolicy.automatic
    var allowsFullSwipe = true
    let swipe = RowSwipeController<ItemID>()
    var onTap: (@MainActor (ItemID) -> Void)?
    var isSwipeAllowed: @MainActor () -> Bool = { false }

    func actions(for id: ItemID, edge: RowSwipeEdge) -> [RowAction<ItemID>] {
        (edge == .leading ? leadingActions : trailingActions)?(id) ?? []
    }

    func allActions(for id: ItemID) -> [RowAction<ItemID>] {
        actions(for: id, edge: .leading) + actions(for: id, edge: .trailing)
    }
}

/// The node of one table row: optional section header, the row with its actions revealed
/// underneath, and a separator (R12c). The user's content node sits inside unchanged.
///
/// Ownership: owns its chrome nodes and the content node given to it; references the table's
/// context weakly. Isolation: MainActor. Errors: none. Cancellation: `dispose()` (inherited).
@MainActor
public final class TableCellNode<ItemID: Hashable & Sendable, Content: Node>: Node {
    /// The user's content node.
    ///
    /// Ownership: owned child. Isolation: MainActor. Errors: none. Cancellation: disposed with
    /// the cell.
    public let content: Content

    /// Stable identity of the row's item.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let itemID: ItemID

    private weak var context: TableCellContext<ItemID>?
    private var header: Node?
    private var headerSection: String?
    private let row = Node()
    private let actionsLayer = Node()
    private let wrapper = ControlNode()
    private let separator = Node()
    private let swipeRecognizer = RowSwipeRecognizer()
    private var shownActions: [String] = []

    init(content: Content, itemID: ItemID, context: TableCellContext<ItemID>) {
        self.content = content
        self.itemID = itemID
        self.context = context
        super.init()
        style.flexDirection = .column
        // The row's content (not the whole cell) is one accessibility element carrying the
        // actions; the section header above and revealed action buttons stay separate elements.
        wrapper.accessibility.isElement = true
        wrapper.accessibility.childrenPolicy = .combine
        row.style.flexDirection = .row
        row.style.visual = LayoutVisualProperties(overflow: .hidden)
        actionsLayer.style.positionType = .absolute
        actionsLayer.style.offsets = DirectionalEdgeOffsets(top: 0, leading: 0)
        actionsLayer.style.width = .fraction(1)
        actionsLayer.style.height = .fraction(1)
        actionsLayer.style.flexDirection = .row
        actionsLayer.style.justifyContent = .spaceBetween
        wrapper.style.flexGrow = 1
        wrapper.style.flexShrink = 1
        wrapper.style.flexDirection = .column
        content.style.width = .fraction(1)
        separator.style.height = .points(0.5)
        row.addSubnode(actionsLayer)
        row.addSubnode(wrapper)
        wrapper.addSubnode(content)
        addSubnode(row)
        addSubnode(separator)

        swipeRecognizer.onSwipe = { [weak self] state, translation in
            self?.swiped(state, physical: translation)
        }
        // The content is a control: a tap, the remote's select, Return/Space on the focused
        // row and the accessibility activate action all select the row, and focus movement
        // (tvOS remote, keyboard) can reach and reveal rows.
        wrapper.activation = { [weak self] in
            guard let self else { return }

            self.context?.onTap?(self.itemID)
        }
        wrapper.onAccessibilityAction = { [weak self] action in
            self?.performRowAction(action) ?? false
        }
        // The control's own tap sits on the content only: a tap on a revealed action button
        // must not also count as a row tap (which would close the row before the action
        // reports its outcome).
        row.addGestureRecognizer(swipeRecognizer)
    }

    /// Shows the row's section context and selection.
    func apply<Item>(_ tableRow: TableRow<Item>) {
        guard let context else { return }

        let appearance = context.appearance
        if tableRow.isFirstInSection, headerSection != tableRow.sectionID {
            header?.dispose()
            header = context.sectionHeader?(tableRow.sectionID)
            if let header {
                insertSubnode(header, at: 0)
            }
            headerSection = tableRow.sectionID
        } else if !tableRow.isFirstInSection, header != nil {
            header?.dispose()
            header = nil
            headerSection = nil
        }
        wrapper.appearance.background = .color(
            tableRow.isSelected ? appearance.selectedBackground : appearance.rowBackground
        )
        if let color = appearance.separatorColor, !tableRow.isLastInSection {
            separator.appearance.background = .color(color)
            separator.style.margin = DirectionalEdgeInsets(
                top: 0,
                leading: appearance.separatorInset,
                bottom: 0,
                trailing: 0
            )
            separator.style.height = .points(0.5)
        } else {
            separator.style.height = .points(0)
        }
        wrapper.accessibility.isSelected = tableRow.isSelected
        wrapper.accessibility.identifier = content.accessibility.identifier
        wrapper.accessibility.customActions = context.allActions(for: itemID).map {
            AccessibilityCustomAction(id: $0.id, name: $0.title)
        }
        renderSwipe()
    }

    /// The accessibility element of the row — carries selection, identifier and custom actions.
    ///
    /// Ownership: owned child. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var rowElement: Node { wrapper }

    /// Accessibility and other non-gesture input run the same actions (P6.6).
    private func performRowAction(_ action: AccessibilityAction) -> Bool {
        guard case .custom(let id) = action, let context,
            let rowAction = context.allActions(for: itemID).first(where: { $0.id == id })
        else { return false }

        return context.swipe.perform(rowAction, for: itemID)
    }

    /// Re-renders the reveal offset and the action buttons from the table's swipe state.
    func renderSwipe() {
        guard let context else { return }

        let swipe = context.swipe
        let offset = swipe.offset(for: itemID)
        let rightToLeft = environment.layoutDirection == .rightToLeft
        let physical = rightToLeft ? -offset : offset
        var visual = wrapper.style.visual
        visual = LayoutVisualProperties(
            zIndex: visual.zIndex,
            overflow: visual.overflow,
            opacity: visual.opacity,
            transform: LayoutTransform(translationX: physical)
        )
        if wrapper.style.visual != visual {
            wrapper.style.visual = visual
        }

        let open = swipe.openRow == itemID && swipe.revealed > 0
        let edge = swipe.edge
        let actions = open ? context.actions(for: itemID, edge: edge) : []
        let failed: String? = {
            if case .failed(let actionID, _) = swipe.phase, open { return actionID }
            return nil
        }()
        let key = actions.map { "\($0.id)\($0.id == failed ? "!" : "")" } + ["\(edge)"]
        guard key != shownActions else { return }

        shownActions = key
        for child in actionsLayer.subnodes {
            child.dispose()
        }
        guard !actions.isEmpty else { return }

        let group = Node()
        group.style.flexDirection = .row
        group.style.height = .fraction(1)
        for action in actions {
            group.addSubnode(
                button(for: action, failed: action.id == failed, width: swipe.buttonWidth)
            )
        }
        if edge == .trailing {
            actionsLayer.addSubnode(Node())
        }
        actionsLayer.addSubnode(group)
    }

    private func button(for action: RowAction<ItemID>, failed: Bool, width: Double) -> Node {
        let appearance = context?.appearance ?? TableAppearance()
        let button = ControlNode(
            appearance: VisualStyle(
                background: .color(
                    action.style == .destructive
                        ? appearance.destructiveBackground : appearance.actionBackground
                )
            )
        )
        button.style.width = .points(width)
        button.style.height = .fraction(1)
        button.style.justifyContent = .center
        button.style.alignItems = .center
        let title = TextNode(
            text: failed ? "Retry" : action.title,
            textStyle: TextStyle(
                pointSize: 14,
                weight: .semibold,
                alignment: .center,
                color: ThemeColor(red: 1, green: 1, blue: 1)
            )
        )
        button.addSubnode(title)
        button.accessibility.label = failed ? "Retry \(action.title)" : action.title
        button.accessibility.role = .button
        button.accessibility.childrenPolicy = .combine
        let id = itemID
        button.activation = { [weak context] in
            _ = context?.swipe.perform(action, for: id)
        }
        return button
    }

    private func swiped(_ state: GestureState, physical: Double) {
        guard let context else { return }

        let rightToLeft = environment.layoutDirection == .rightToLeft
        let reading = rightToLeft ? -physical : physical
        let leading = context.actions(for: itemID, edge: .leading)
        let trailing = context.actions(for: itemID, edge: .trailing)
        let width = calculatedFrame?.width ?? 0
        switch state {
        case .began, .changed:
            let base = state == .began ? 0 : lastTranslation
            lastTranslation = reading
            context.swipe.track(
                itemID,
                translation: reading - base,
                leadingCount: leading.count,
                trailingCount: trailing.count,
                rowWidth: width
            )
        case .ended:
            lastTranslation = 0
            let edge = context.swipe.edge
            let actions = edge == .leading ? leading : trailing
            let full = context.swipe.release(
                itemID,
                actionCount: actions.count,
                rowWidth: width,
                allowsFullSwipe: context.allowsFullSwipe
            )
            if full, let first = actions.first {
                context.swipe.perform(first, for: itemID)
            }
        default:
            lastTranslation = 0
            context.swipe.close()
        }
    }

    private var lastTranslation = 0.0

    /// Enables or disables the swipe gesture on this cell.
    func setSwipeEnabled(_ enabled: Bool) {
        let registered = row.gestureRecognizers.contains { $0 === swipeRecognizer }
        if enabled, !registered {
            row.addGestureRecognizer(swipeRecognizer)
        } else if !enabled, registered {
            row.removeGestureRecognizer(swipeRecognizer)
        }
    }
}

/// Wraps the user's provider into table cells (R12c).
///
/// Ownership: retains the user's provider and the table's cell context. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public struct TableCellProvider<Base: ItemProvider>: ItemProvider {
    /// Identity type of the rows.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias ItemID = Base.ItemID

    /// Row model the window sees.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Item = TableRow<Base.Item>

    /// Node type of each row.
    ///
    /// Ownership: a type alias. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Content = TableCellNode<Base.ItemID, Base.Content>

    let base: Base
    let context: TableCellContext<Base.ItemID>

    /// Makes the user's node and wraps it in a cell.
    ///
    /// Ownership: the window owns the returned cell. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func makeNode(for item: TableRow<Base.Item>, id: Base.ItemID) -> TableCellNode<
        Base.ItemID, Base.Content
    > {
        let cell = TableCellNode(
            content: base.makeNode(for: item.value, id: id),
            itemID: id,
            context: context
        )
        cell.setSwipeEnabled(context.isSwipeAllowed())
        cell.apply(item)
        return cell
    }

    /// Updates the user's node and the cell chrome.
    ///
    /// Ownership: the cell stays window-owned. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func update(
        _ node: TableCellNode<Base.ItemID, Base.Content>,
        with item: TableRow<Base.Item>,
        id: Base.ItemID
    ) {
        base.update(node.content, with: item.value, id: id)
        node.setSwipeEnabled(context.isSwipeAllowed())
        node.apply(item)
    }

    /// Replaces the cell when the user's provider cannot update its content.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func canUpdate(
        _ node: TableCellNode<Base.ItemID, Base.Content>,
        to item: TableRow<Base.Item>
    ) -> Bool {
        base.canUpdate(node.content, to: item.value)
    }
}

/// A vertically scrolling table of rows in sections, with separators, selection and swipe
/// actions (R12c, ADR 0034) — the shared `CollectionNode` runtime with a cell wrapper. Section
/// headers are composed into the first row of each section; swipe actions follow P6.6 and stay
/// available to accessibility when the gesture is disabled.
///
/// Ownership: see `CollectionNode`; owns the swipe controller and its action tasks.
/// Isolation: MainActor. Errors: none — action failures are shown on the row. Cancellation:
/// see `CollectionNode`; `dispose()` also drops running actions.
@MainActor
public final class TableNode<Provider: ItemProvider>: CollectionNode<
    TableCellProvider<Provider>, Provider.Item
>
{
    /// Selected item IDs. Durable state: the model may own it and assign it; taps update it
    /// according to `selectionMode`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var selection: Set<ItemID> = [] {
        didSet { if selection != oldValue { refreshRows() } }
    }

    /// How taps change `selection`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var selectionMode = TableSelectionMode.single

    /// Swipe gesture policy (P6.6).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var swipeActionsPolicy: SwipeActionsPolicy {
        get { context.swipeActionsPolicy }
        set {
            context.swipeActionsPolicy = newValue
            refreshRows()
        }
    }

    /// Whether dragging past `fullSwipeFraction` performs the first action.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var allowsFullSwipe: Bool {
        get { context.allowsFullSwipe }
        set { context.allowsFullSwipe = newValue }
    }

    /// Row and chrome colors.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var tableAppearance: TableAppearance {
        get { context.appearance }
        set {
            context.appearance = newValue
            refreshRows()
        }
    }

    /// The table's swipe state — which row is open and its phase.
    ///
    /// Ownership: owned. Isolation: MainActor. Errors: none. Cancellation: `cancelAll()`.
    public var swipe: RowSwipeController<ItemID> { context.swipe }

    private let context: TableCellContext<ItemID>

    /// Creates a table over `source`.
    ///
    /// Ownership: retains `source` and `provider`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(
        source: StateSubject<CollectionSnapshot<Provider.ItemID, Provider.Item>>,
        provider: Provider,
        estimatedRowHeight: Double = 44,
        pagination: PaginationPolicy = PaginationPolicy(),
        ranges: PreparationRanges = PreparationRanges(),
        maximumMaterializedCount: Int = 64,
        style: LayoutStyle = LayoutStyle()
    ) {
        let context = TableCellContext<Provider.ItemID>()
        self.context = context
        let selectionBox = SelectionBox<Provider.ItemID>()
        self.selectionBox = selectionBox
        let cellProvider = TableCellProvider(base: provider, context: context)
        super.init(
            source: source,
            provider: cellProvider,
            transform: { snapshot in
                Self.rows(of: snapshot, selection: selectionBox.selection)
            },
            grid: nil,
            estimatedLength: estimatedRowHeight,
            spacing: 0,
            pagination: pagination,
            ranges: ranges,
            maximumMaterializedCount: maximumMaterializedCount,
            style: style
        )
        scrollNode.configuration.directionalLockEnabled = true
        context.isSwipeAllowed = { [weak self, weak context] in
            guard let self, let context else { return false }

            let hasActions = context.leadingActions != nil || context.trailingActions != nil
            return context.swipeActionsPolicy.allowsSwipe(
                hasActions: hasActions,
                contextAllows: self.environment[RowSwipeContextKey.self]
            )
        }
        context.onTap = { [weak self] id in self?.tapped(id) }
        context.swipe.onChange = { [weak self] id in
            guard let self, let id else { return }

            self.window.node(for: id)?.renderSwipe()
        }
    }

    /// Section header for a section ID, composed into the section's first row.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var sectionHeader: (@MainActor (String) -> Node?)? {
        get { context.sectionHeader }
        set {
            context.sectionHeader = newValue
            refreshRows()
        }
    }

    /// Actions revealed by dragging toward the trailing side.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var leadingActions: (@MainActor (ItemID) -> [RowAction<ItemID>])? {
        get { context.leadingActions }
        set {
            context.leadingActions = newValue
            refreshRows()
        }
    }

    /// Actions revealed by dragging toward the leading side.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var trailingActions: (@MainActor (ItemID) -> [RowAction<ItemID>])? {
        get { context.trailingActions }
        set {
            context.trailingActions = newValue
            refreshRows()
        }
    }

    /// The cell of `id`, if materialized.
    ///
    /// Ownership: the window keeps owning it. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func cell(for id: ItemID) -> TableCellNode<ItemID, Provider.Content>? {
        window.node(for: id)
    }

    /// Drops running actions, then disposes like any collection.
    ///
    /// Ownership: releases tasks and nodes. Isolation: MainActor. Errors: none. Cancellation:
    /// terminal.
    public override func dispose() {
        context.swipe.cancelAll()
        super.dispose()
    }

    override func pageExtras() -> (any Sendable)? {
        selection.isEmpty ? nil : selection
    }

    override func restorePageExtras(_ extras: any Sendable) {
        if let restored = extras as? Set<ItemID> {
            selection = restored
        }
    }

    override func didApply(_ snapshot: CollectionSnapshot<ItemID, TableRow<Provider.Item>>) {
        context.swipe.itemsRemoved { snapshot.contains($0) }
    }

    private let selectionBox: SelectionBox<Provider.ItemID>

    private func tapped(_ id: ItemID) {
        if context.swipe.openRow != nil {
            context.swipe.close()
            return
        }

        switch selectionMode {
        case .none: break
        case .single: selection = [id]
        case .multiple:
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        }
        events.select(id)
    }

    private func refreshRows() {
        selectionBox.selection = selection
        refreshPresentation()
        updateSwipeAvailability()
    }

    /// Re-evaluates the swipe policy on live cells — after a policy change, and on every host
    /// commit so an enclosing container's `RowSwipeContextKey` change takes effect.
    private func updateSwipeAvailability() {
        let allowed = context.isSwipeAllowed()
        for id in window.materializedIDs {
            window.node(for: id)?.setSwipeEnabled(allowed)
        }
        // Swipe progress is transient interaction state (P6.9): a row that left the window
        // closes instead of reappearing half open.
        if !allowed || context.swipe.openRow.map({ window.node(for: $0) == nil }) == true {
            context.swipe.close()
        }
    }

    /// Serves the commit like any collection, then re-checks the swipe context.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public override func hostDidCommit(_ commit: ContainerCommit) {
        super.hostDidCommit(commit)
        updateSwipeAvailability()
    }

    static func rows(
        of snapshot: CollectionSnapshot<Provider.ItemID, Provider.Item>,
        selection: Set<Provider.ItemID>
    ) -> CollectionSnapshot<Provider.ItemID, TableRow<Provider.Item>> {
        CollectionSnapshot(
            dataKey: snapshot.dataKey,
            revision: snapshot.revision,
            sections: snapshot.sections.map { section in
                CollectionSection(
                    id: section.id,
                    items: section.items.enumerated().map { index, item in
                        CollectionItem(
                            id: item.id,
                            value: TableRow(
                                value: item.value,
                                sectionID: section.id,
                                isFirstInSection: index == 0,
                                isLastInSection: index == section.items.count - 1,
                                isSelected: selection.contains(item.id)
                            )
                        )
                    }
                )
            },
            loadState: snapshot.loadState
        )
    }
}

/// Selection read by the snapshot transform without capturing the table.
@MainActor
final class SelectionBox<ItemID: Hashable & Sendable> {
    var selection: Set<ItemID> = []
}
