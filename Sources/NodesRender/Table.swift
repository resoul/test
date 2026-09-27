#if canImport(CoreText)
    import LayoutCore
    import Nodes

    /// An action a table row offers when swiped aside, as a button behind it.
    ///
    /// Ownership: value holding the closure. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public struct SwipeAction {
        /// What the action does to the row's item.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public enum Role: Sendable, Hashable {
            /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
            case normal
            /// It removes or destroys the item: red by default.
            ///
            /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
            case destructive
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var title: String
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var color: Color
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var role: Role
        /// Ownership: the action keeps the closure; it must not keep the table. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var perform: @MainActor () -> Void

        /// An action showing `title` on `color` — red for a destructive one, gray otherwise,
        /// by default.
        ///
        /// Ownership: keeps `perform`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(
            _ title: String,
            color: Color? = nil,
            role: Role = .normal,
            perform: @escaping @MainActor () -> Void
        ) {
            self.title = title
            self.role = role
            self.color =
                color
                ?? (role == .destructive
                    ? Color(red: 0.92, green: 0.26, blue: 0.24)
                    : Color(red: 0.56, green: 0.57, blue: 0.60))
            self.perform = perform
        }
    }

    /// Rows of a table under a title.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct TableSection<Item: Identifiable> {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var id: String
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var title: String?
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var items: [Item]

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(id: String, title: String? = nil, items: [Item]) {
            self.id = id
            self.title = title
            self.items = items
        }
    }

    /// Rows in sections, laid out only near the window, each tapped to select it and swiped
    /// aside to show its actions — as a list in Mail or Settings.
    ///
    ///     let inbox = Table<Message> { message in cells[message.id].showing(message) }
    ///     inbox.sections = [TableSection(id: "inbox", items: messages)]
    ///     inbox.trailingActions = { message in
    ///         [SwipeAction("Delete", role: .destructive) { model.delete(message) }]
    ///     }
    ///
    /// A swipe toward the leading side shows the trailing actions, and the other way the
    /// leading ones; a swipe past most of the row does the first action at once. A tap on a
    /// row with its actions shown puts it back; one row shows its actions at a time.
    /// VoiceOver offers the actions of a row as its element's actions. On a TV a row is
    /// selected, not swiped.
    ///
    /// Ownership: the table keeps `row` and the nodes it returns while they show. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    @MainActor
    public final class Table<Item: Identifiable>: Node {
        /// The table's own scroll, when it scrolls itself; `nil` when it lies in a scroll
        /// around it.
        ///
        /// Ownership: owned by the table. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public let scroll: Scroll?

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var sections: [TableSection<Item>] = [] {
            didSet { stack.items = entries() }
        }

        /// What a tap on a row does. Without it, the remote of a TV does not go to the rows.
        ///
        /// Ownership: the table keeps the closure; it must not keep the table. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var onSelect: (@MainActor (Item) -> Void)? {
            didSet { setNeedsLayout() }
        }

        /// The actions shown at the leading side of a row swiped toward the trailing one.
        ///
        /// Ownership: the table keeps the closure; it must not keep the table. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var leadingActions: (@MainActor (Item) -> [SwipeAction])? {
            didSet { setNeedsLayout() }
        }

        /// The actions shown at the trailing side of a row swiped toward the leading one.
        ///
        /// Ownership: the table keeps the closure; it must not keep the table. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var trailingActions: (@MainActor (Item) -> [SwipeAction])? {
            didSet { setNeedsLayout() }
        }

        /// The row showing its actions, if any.
        private weak var openRow: TableRow?
        private let rowContent: @MainActor (Item) -> Node
        private let rows: NodeCache<Item.ID, TableRow>
        private let headers = NodeCache<String, SectionHeader> { _ in SectionHeader() }
        private lazy var stack = LazyStack<Entry>(estimatedLength: estimatedRowHeight) {
            [unowned self] entry in node(for: entry)
        }
        private let estimatedRowHeight: Double

        /// A table of rows `row` makes for each item — it may keep and return the same node
        /// for an item, as with a `NodeCache`. `scrolls: false` lays it in the scroll around
        /// it instead of a scroll of its own.
        ///
        /// Ownership: keeps `row`. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        public init(
            scrolls: Bool = true,
            estimatedRowHeight: Double = 44,
            row: @escaping @MainActor (Item) -> Node
        ) {
            rowContent = row
            rows = NodeCache { _ in TableRow() }
            self.estimatedRowHeight = estimatedRowHeight
            scroll = scrolls ? Scroll(.vertical) : nil
            super.init()
            scroll?.content = stack
            scroll?.onScroll = { [weak self] _ in self?.closeOpenRow() }
        }

        /// Puts back the row showing its actions, if any.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func closeOpenRow() {
            openRow?.close()
            openRow = nil
        }

        /// Ownership: returns a value borrowing the scroll or the stack. Isolation:
        /// MainActor. Errors: none. Cancellation: none.
        public override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                if let scroll { scroll } else { stack }
            }
        }

        // MARK: - Rows

        /// A header or a row, in the order they are laid out.
        private enum Entry: Identifiable {
            case header(id: String, title: String)
            case row(Item)

            var id: EntryID {
                switch self {
                case let .header(id, _): .header(id)
                case let .row(item): .row(item.id)
                }
            }
        }

        private enum EntryID: Hashable {
            case header(String)
            case row(Item.ID)
        }

        private func entries() -> [Entry] {
            sections.flatMap { section -> [Entry] in
                let header = section.title.map { [Entry.header(id: section.id, title: $0)] } ?? []
                return header + section.items.map(Entry.row)
            }
        }

        private func node(for entry: Entry) -> Node {
            switch entry {
            case let .header(id, title):
                let header = headers[id]
                header.title = title
                return header
            case let .row(item):
                let row = rows[item.id]
                row.show(
                    rowContent(item),
                    leading: leadingActions?(item) ?? [],
                    trailing: trailingActions?(item) ?? [],
                    selects: onSelect != nil,
                    select: { [weak self] in self?.onSelect?(item) }
                )
                row.table = { [weak self] in self }
                return row
            }
        }

        /// A row shows its actions: the one that did is put back.
        func rowOpened(_ row: TableRow) {
            if openRow !== row {
                openRow?.close()
            }
            openRow = row
        }

        func rowClosed(_ row: TableRow) {
            if openRow === row {
                openRow = nil
            }
        }
    }

    /// A table's row: the content on a cell that moves aside over the buttons of its actions.
    @MainActor
    final class TableRow: Node {
        let cell = Cell()
        private(set) var leading: [ActionButton] = []
        private(set) var trailing: [ActionButton] = []
        /// The table the row is in, for which row shows its actions.
        var table: (@MainActor () -> TableOpening?)?
        /// Where the cell was when a drag began, along the row, from the reading side.
        private var dragStart = 0.0

        override init() {
            super.init()
            dragAxis = .horizontal
            onDrag = { [unowned self] drag in dragged(drag) }
        }

        func show(
            _ content: Node,
            leading: [SwipeAction],
            trailing: [SwipeAction],
            selects: Bool,
            select: @escaping @MainActor () -> Void
        ) {
            if cell.content !== content {
                cell.content = content
            }
            self.leading = buttons(for: leading, existing: self.leading)
            self.trailing = buttons(for: trailing, existing: self.trailing)
            cell.onTap = { [unowned self] in
                if position != 0 {
                    close()
                } else {
                    select()
                }
            }
            // The remote goes to rows there is something to do with: selecting them.
            cell.isFocusable = selects
            cell.accessibilityActions = (leading + trailing).map { action in
                AccessibilityAction(name: action.title) {
                    action.perform()
                    return true
                }
            }
        }

        private func buttons(for actions: [SwipeAction], existing: [ActionButton])
            -> [ActionButton]
        {
            actions.enumerated().map { index, action in
                let button = index < existing.count ? existing[index] : ActionButton()
                button.show(action) { [unowned self] in
                    close()
                    action.perform()
                }
                return button
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                // Behind the cell, which is drawn over them.
                if !leading.isEmpty {
                    FlexContainer(.row) {
                        for button in leading { button }
                    }
                    .absolute(top: 0, leading: 0, bottom: 0)
                }
                if !trailing.isEmpty {
                    FlexContainer(.row) {
                        for button in trailing { button }
                    }
                    .absolute(top: 0, bottom: 0, trailing: 0)
                }
                cell.flex(grow: 1)
            }
        }

        // MARK: - Swipe

        /// How far the cell is moved, from the reading side: below zero it shows the trailing
        /// actions, above zero the leading ones.
        var position: Double {
            cell.appearance.offset.x * readingSign
        }

        /// 1 laid out from the left, -1 from the right: trailing is where the reading goes.
        private var readingSign: Double {
            host?.direction == .rightToLeft ? -1 : 1
        }

        private func width(of buttons: [ActionButton]) -> Double {
            buttons.reduce(0) { $0 + $1.frame.size.width }
        }

        private func move(to position: Double) {
            cell.appearance.offset = LayoutPoint(x: position * readingSign, y: 0)
        }

        private func settle(at position: Double) {
            withAnimation(TableRow.settling) {
                move(to: position)
            }
            if position == 0 {
                table?()?.rowClosed(self)
            } else {
                table?()?.rowOpened(self)
            }
        }

        private static let settling = Animation.spring(response: 0.3, dampingRatio: 1)

        /// Points a second a flick must go for the actions to show.
        private static let flick = 300.0

        func close() {
            guard position != 0 else { return }

            settle(at: 0)
        }

        private func dragged(_ drag: Drag) {
            let along = drag.translation.x * readingSign
            let length = frame.size.width
            switch drag.phase {
            case .began:
                dragStart = position
            case .changed:
                var now = dragStart + along
                // Only toward actions there are; past them up to the row's width.
                now = min(max(now, trailing.isEmpty ? 0 : -length), leading.isEmpty ? 0 : length)
                move(to: now)
            case .ended:
                end(at: position, speed: drag.velocity.x * readingSign, length: length)
            case .cancelled:
                settle(at: dragStart)
            }
        }

        /// Where a swipe let go at `position`, moving at `speed`, comes to rest: past most of
        /// the row, it does the first action; past half the buttons or flicked, it shows
        /// them; else it goes back.
        private func end(at position: Double, speed: Double, length: Double) {
            let (buttons, side) = position < 0 ? (trailing, -1.0) : (leading, 1.0)
            let shown = width(of: buttons)
            let past = abs(position)
            guard !buttons.isEmpty, past > 0 else {
                settle(at: 0)
                return
            }

            if past > length * TableRow.fullSwipe, let first = buttons.first {
                withAnimation(TableRow.settling) {
                    move(to: side * length)
                }
                first.press()
                return
            }
            let flickedOpen = speed * side > TableRow.flick
            let flickedShut = speed * side < -TableRow.flick
            if !flickedShut && (past > shown / 2 || flickedOpen) {
                settle(at: side * shown)
            } else {
                settle(at: 0)
            }
        }

        /// The share of the row a swipe must pass to do the first action.
        private static let fullSwipe = 0.6
    }

    /// What a row tells its table: it shows its actions, or no longer does.
    @MainActor
    protocol TableOpening: AnyObject {
        func rowOpened(_ row: TableRow)
        func rowClosed(_ row: TableRow)
    }

    extension Table: TableOpening {}

    /// The part of a row that moves aside: the content on the row's background, and a line
    /// under it.
    @MainActor
    final class Cell: Node {
        var content: Node? {
            didSet { setNeedsLayout() }
        }
        private let separator = Node()

        override init() {
            super.init()
            appearance.background = .white
            separator.appearance.background = Color(red: 0.85, green: 0.86, blue: 0.88)
            // One element, the content's text read as one, with the actions of the row.
            accessibility.isElement = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                if let content { content }
                separator
                    .absolute(leading: 16, bottom: 0, trailing: 0)
                    .height(.points(0.5))
            }
        }

        override func pressChanged(_ isPressed: Bool) {
            appearance.background =
                isPressed ? Color(red: 0.90, green: 0.91, blue: 0.93) : .white
        }
    }

    /// A button of a row's action, behind the cell: the row offers its actions to assistive
    /// technologies itself.
    @MainActor
    final class ActionButton: Node {
        let label = Text("", style: TextStyle(size: 15, weight: .semibold, color: .white))
        private var action: (@MainActor () -> Void)?

        override init() {
            super.init()
            accessibility.isElement = false
            label.accessibility.isElement = false
            // Behind the cell: the remote does not go to it; the row's actions are there
            // for assistive technologies.
            isFocusable = false
        }

        func show(_ swipe: SwipeAction, perform: @escaping @MainActor () -> Void) {
            label.text = swipe.title
            appearance.background = swipe.color
            action = perform
            onTap = perform
        }

        /// Does the action, as a tap does.
        func press() {
            action?()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { label }
                .alignItems(.center)
                .padding(top: 0, leading: 20, bottom: 0, trailing: 20)
        }
    }

    /// A section's title over its rows.
    @MainActor
    final class SectionHeader: Node {
        let label = Text(
            "",
            style: TextStyle(
                size: 13,
                weight: .semibold,
                color: Color(red: 0.45, green: 0.47, blue: 0.52)
            )
        )

        var title: String {
            get { label.text }
            set { label.text = newValue }
        }

        override init() {
            super.init()
            appearance.background = Color(red: 0.96, green: 0.96, blue: 0.97)
            label.accessibility.traits.insert(.header)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { label }
                .padding(top: 16, leading: 16, bottom: 6, trailing: 16)
        }
    }
#endif
