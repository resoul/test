#if canImport(CoreText)
    import Foundation
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

    /// Where a row is in a table: its section and its place among the section's items.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct TablePosition: Sendable, Hashable {
        /// The `id` of the section.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var section: String
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var index: Int

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(section: String, index: Int) {
            self.section = section
            self.index = index
        }
    }

    /// A row the user moved: the item, where it was and where it is now — `to.index` among
    /// the items of its section once it is there.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct TableMove<ID: Hashable>: Hashable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var item: ID
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var from: TablePosition
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var to: TablePosition
    }

    extension TableMove: Sendable where ID: Sendable {}

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
    /// Edited (`isEditing`), rows do not swipe: with `onMove` each shows a handle at its
    /// trailing side that lifts it to be dragged to another place, and with
    /// `allowsMultipleSelectionDuringEditing` a mark at its leading side, and a tap selects
    /// it or no longer does (`selection`). VoiceOver moves a row up or down by one with the
    /// element's actions.
    ///
    ///     inbox.onMove = { move in model.move(move.item, to: move.to) }
    ///     withAnimation { inbox.isEditing = true }
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
            didSet {
                // A row let go is in its place in the new sections already.
                if !committing {
                    let entries = entries()
                    // Rows in another order leave the rows moved where they have them.
                    if entries.map(\.id) != stack.items.map(\.id) {
                        endMoving()
                    }
                    stack.items = entries
                }
                let ids = Set(sections.flatMap { $0.items.map(\.id) })
                if !selection.isSubset(of: ids) {
                    selection.formIntersection(ids)
                    onSelectionChange?(selection)
                }
            }
        }

        /// Whether the table is edited: rows do not swipe, and show a handle to move them
        /// (with `onMove`) and a mark of their selection (with
        /// `allowsMultipleSelectionDuringEditing`). Inside `withAnimation` they change with
        /// the animation. Ending it puts a row being moved where it is dragged to.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isEditing = false {
            didSet {
                guard isEditing != oldValue else { return }

                closeOpenRow()
                if !isEditing {
                    drop()
                }
                setNeedsLayout()
            }
        }

        /// Whether, while edited, a tap on a row selects it or no longer does, and each row
        /// shows whether it is selected.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var allowsMultipleSelectionDuringEditing = false {
            didSet { setNeedsLayout() }
        }

        /// The items selected, by their ids. A tap changes it and tells `onSelectionChange`;
        /// setting it tells nothing. The ids of items no longer in `sections` leave it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var selection: Set<Item.ID> = [] {
            didSet { if selection != oldValue { setNeedsLayout() } }
        }

        /// What a tap that selected a row or no longer did does, told the whole selection.
        ///
        /// Ownership: the table keeps the closure; it must not keep the table. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var onSelectionChange: (@MainActor (Set<Item.ID>) -> Void)?

        /// Told each row the user moved, once it is in its new place — the table has put it
        /// there in `sections`; the model follows. Without it, rows do not move.
        ///
        /// Ownership: the table keeps the closure; it must not keep the table. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var onMove: (@MainActor (TableMove<Item.ID>) -> Void)? {
            didSet { setNeedsLayout() }
        }

        /// Whether the row of an item can be moved; every row can without it.
        ///
        /// Ownership: the table keeps the closure; it must not keep the table. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var canMove: (@MainActor (Item) -> Bool)? {
            didSet { setNeedsLayout() }
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
            stack.onLayoutApplied = { [weak self] in self?.stackLaidOut() }
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
                header.sectionID = id
                return header
            case let .row(item):
                let row = rows[item.id]
                if lift == nil, landing == nil, settlingRow == nil, shifts.isEmpty {
                    // Nothing is moved aside: a row kept from an earlier move shows in place.
                    row.appearance.offset = .zero
                }
                row.show(
                    rowContent(item),
                    leading: leadingActions?(item) ?? [],
                    trailing: trailingActions?(item) ?? [],
                    selects: onSelect != nil,
                    select: { [weak self] in self?.onSelect?(item) },
                    editing: isEditing ? editing(item) : nil
                )
                row.table = { [weak self] in self }
                row.itemID = item.id
                return row
            }
        }

        private func editing(_ item: Item) -> RowEditing {
            let id = item.id
            var editing = RowEditing(
                marksSelection: allowsMultipleSelectionDuringEditing,
                isSelected: selection.contains(id),
                toggle: { [weak self] in self?.toggle(id) }
            )
            if onMove != nil, canMove?(item) ?? true {
                editing.drag = { [weak self] drag in self?.dragged(id, drag) }
                editing.step = { [weak self] step in self?.move(id, by: step) ?? false }
            }
            return editing
        }

        private func toggle(_ id: Item.ID) {
            guard isEditing, allowsMultipleSelectionDuringEditing else { return }

            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            // Its mark shows it at once; the layout that shows the rest may come later.
            let row = mountedEntries(in: stack.items).first { $0.id == .row(id) }?.node
            (row as? TableRow)?.cell.editing?.isSelected = selection.contains(id)
            onSelectionChange?(selection)
        }

        // MARK: - Moving rows

        /// A row lifted by its handle: it follows the drag over the others, which move aside
        /// to make room for it where it would go. They are drawn moved rather than laid out
        /// again, so that nothing waits for a layout while the drag goes on.
        private struct Lift {
            let id: Item.ID
            let row: TableRow
            let from: TablePosition
            /// The order before the lift, for a lift the system takes away.
            let original: [Entry]
            let scroll: Scroll
            /// Where the row's box started, as laid out, and the scroll's offset then.
            let startTop: Double
            let startOffset: Double
            /// How far the drag moved, down the table.
            var translation = 0.0
            /// The order the mounted nodes are laid out in: behind `stack.items` until a
            /// layout of a new order is mounted.
            var laidOut: [Entry]
            /// Where the row is drawn, and where among the others it goes, as last followed.
            var top = 0.0
            var slot = 0
            /// Points a second the scroll moves while the row is held near its edge.
            var speed = 0.0
        }

        private var lift: Lift?
        /// `sections` takes a row let go into the place the stack has it in already.
        private var committing = false
        /// A row let go, drawn where it was let go until the layout of its new place is
        /// mounted.
        private var landing: (row: TableRow, top: Double)?
        /// A row going down into its place, lifted until it gets there.
        private var settlingRow: TableRow?
        /// Where nodes are drawn moved to along the table: each goes a step there on every
        /// frame, as the renderer draws a whole frame with one animation and the lifted row
        /// follows the drag without one.
        private var shifts: [ObjectIdentifier: (node: Node, to: Double)] = [:]
        private var frameTimer: Timer?
        private var frameTicker: FrameTicker?
        private var lastFrame: Double?

        private func dragged(_ id: Item.ID, _ drag: Drag) {
            switch drag.phase {
            case .began:
                begin(id)
            case .changed:
                lift?.translation = drag.translation.y
                follow()
            case .ended:
                lift?.translation = drag.translation.y
                follow()
                drop()
            case .cancelled:
                cancelLift()
            }
        }

        private func begin(_ id: Item.ID) {
            guard lift == nil, landing == nil, isEditing, let scroll = scroll ?? enclosingScroll,
                let row = mountedEntries(in: stack.items).first(where: { $0.id == .row(id) })?
                    .node as? TableRow,
                let frame = scroll.frame(of: row), let from = position(of: id)
            else { return }

            closeOpenRow()
            if let settlingRow {
                settle(settlingRow)
            }
            lift = Lift(
                id: id,
                row: row,
                from: from,
                original: stack.items,
                scroll: scroll,
                startTop: frame.origin.y,
                startOffset: scroll.contentOffset.y,
                laidOut: stack.items,
                top: frame.origin.y + row.appearance.offset.y
            )
            row.lifted(true)
        }

        /// Puts the lifted row under the drag, moves the others aside to where its middle
        /// is, and scrolls while it is held near the window's edge. `now` puts the others
        /// there at once, for a new layout under them.
        private func follow(now: Bool = false) {
            guard var lift,
                let current = lift.laidOut.firstIndex(where: { $0.id == .row(lift.id) }),
                let frame = lift.scroll.frame(of: lift.row)
            else { return }

            let length = frame.size.height
            let top = top(of: lift, length)
            let mounted = mountedEntries(in: lift.laidOut)
            let slot = slot(
                for: top + length / 2,
                moving: current,
                length: length,
                mounted: mounted,
                in: lift.scroll
            )
            for entry in mounted where entry.index != current {
                // Its place with the lifted row out of the list, and whether that is after
                // where the row goes.
                let rank = entry.index > current ? entry.index - 1 : entry.index
                let aside = (rank >= slot ? length : 0) - (entry.index > current ? length : 0)
                shift(entry.node, to: aside, now: now)
            }
            shifts[ObjectIdentifier(lift.row)] = nil
            lift.row.appearance.offset = LayoutPoint(x: 0, y: top - frame.origin.y)
            lift.top = top
            lift.slot = slot
            // Far from its place, the row would leave the part of the list laid out: its
            // place moves to where it is, laid out when a layout gets to it.
            if abs(top - frame.origin.y) > lift.scroll.frame.size.height,
                stack.items.map(\.id) == lift.laidOut.map(\.id)
            {
                var items = lift.laidOut
                items.insert(items.remove(at: current), at: slot)
                stack.setItemsHoldingScroll(items)
            }
            lift.speed = autoscrollSpeed(top: top, length: length, in: lift.scroll)
            self.lift = lift
            runFrames()
        }

        /// Where the lifted row's box is to be drawn: moved by the drag and by the scroll
        /// since the lift, within the table.
        private func top(of lift: Lift, _ length: Double) -> Double {
            let top =
                lift.startTop + lift.translation + lift.scroll.contentOffset.y - lift.startOffset
            guard let box = lift.scroll.frame(of: stack) else { return top }

            return min(max(top, box.origin.y), box.origin.y + box.size.height - length)
        }

        /// The place among the entries, the lifted one at `current` taken out, where those
        /// before it end above `middle` — not before the first section's title.
        private func slot(
            for middle: Double,
            moving current: Int,
            length: Double,
            mounted: [(index: Int, id: EntryID, node: Node)],
            in scroll: Scroll
        ) -> Int {
            // The entries before those mounted are above it.
            var slot = mounted.first.map { $0.index - (current < $0.index ? 1 : 0) } ?? 0
            for entry in mounted where entry.index != current {
                guard let frame = scroll.frame(of: entry.node) else { break }

                // Where it is laid out with the lifted row out of the list.
                let start = frame.origin.y - (entry.index > current ? length : 0)
                guard start + frame.size.height / 2 < middle else { break }

                slot += 1
            }
            if case .header = stack.items.first {
                slot = max(slot, 1)
            }
            return slot
        }

        /// How fast to scroll for a lifted row at `top`: toward the edge it is held near,
        /// the faster the nearer, while the scroll goes that way.
        private func autoscrollSpeed(top: Double, length: Double, in scroll: Scroll) -> Double {
            let shown = top - scroll.contentOffset.y
            let window = scroll.frame.size.height
            let range = scroll.offsetRange
            let zone = Table.autoscrollZone
            if shown < zone, scroll.contentOffset.y > range.lowest.y {
                return -Table.autoscrollSpeed * min(1, (zone - shown) / zone)
            }
            if shown + length > window - zone, scroll.contentOffset.y < range.highest.y {
                return Table.autoscrollSpeed * min(1, (shown + length - window + zone) / zone)
            }
            return 0
        }

        /// Draws `node` moved by `offset` along the table: a step there each frame, or at
        /// once.
        private func shift(_ node: Node, to offset: Double, now: Bool = false) {
            if now || (shifts[ObjectIdentifier(node)] == nil && node.appearance.offset.y == offset)
            {
                node.appearance.offset = LayoutPoint(x: 0, y: offset)
            }
            shifts[ObjectIdentifier(node)] =
                node.appearance.offset.y == offset ? nil : (node, offset)
        }

        /// A frame `seconds` after the last: the scroll moves at the lifted row's speed, and
        /// the nodes moved aside go a step toward where they go.
        func advance(by seconds: Double) {
            if let lift, lift.speed != 0 {
                var offset = lift.scroll.contentOffset
                offset.y =
                    lift.scroll.offsetRange.clamp(
                        LayoutPoint(x: offset.x, y: offset.y + lift.speed * seconds)
                    ).y
                lift.scroll.contentOffset = offset
                follow()
            }
            // Most of the way in a tenth of a second, easing out.
            let step = 1 - exp(-seconds / Table.shiftTime)
            for (key, shift) in shifts {
                let now = shift.node.appearance.offset.y
                var next = now + (shift.to - now) * step
                if abs(shift.to - next) < 0.5 {
                    next = shift.to
                    shifts[key] = nil
                }
                shift.node.appearance.offset = LayoutPoint(x: 0, y: next)
            }
            if let settlingRow, shifts[ObjectIdentifier(settlingRow)] == nil {
                settle(settlingRow)
            }
            runFrames()
        }

        /// Runs the frames while something moves, and stops them when nothing does.
        private func runFrames() {
            let moves = (lift?.speed ?? 0) != 0 || !shifts.isEmpty
            guard moves != (frameTimer != nil) else { return }

            guard moves else {
                frameTimer?.invalidate()
                frameTimer = nil
                frameTicker = nil
                lastFrame = nil
                return
            }

            lastFrame = ProcessInfo.processInfo.systemUptime
            let ticker = FrameTicker { [weak self] in self?.frameTicked() }
            frameTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) {
                [weak ticker] timer in
                // A table gone takes its frames with it.
                guard let ticker else {
                    timer.invalidate()
                    return
                }

                MainActor.assumeIsolated { ticker.tick() }
            }
            frameTicker = ticker
        }

        private func frameTicked() {
            let now = ProcessInfo.processInfo.systemUptime
            let last = lastFrame ?? now
            lastFrame = now
            advance(by: min(now - last, 0.1))
        }

        /// Lets the lifted row go where it is: the others stay where they are drawn, and once
        /// the layout of the new order is mounted the row goes down into its place.
        /// `sections` has it there at once, and `onMove` is told.
        private func drop() {
            guard var lift else { return }

            self.lift = nil
            lift.speed = 0
            guard let current = lift.laidOut.firstIndex(where: { $0.id == .row(lift.id) }) else {
                settle(lift.row)
                return
            }

            var items = lift.laidOut
            items.insert(items.remove(at: current), at: lift.slot)
            if items.map(\.id) == stack.items.map(\.id), lift.slot == current {
                // Where it is laid out: it goes down into its place from where it is.
                goDown(lift.row)
            } else {
                landing = (lift.row, lift.top)
                stack.setItemsHoldingScroll(items)
            }
            runFrames()
            guard let to = landing(of: lift.id, in: items), to != lift.from else { return }

            let move = TableMove(item: lift.id, from: lift.from, to: to)
            committing = true
            sections = applying(move, to: sections)
            committing = false
            onMove?(move)
        }

        private func cancelLift() {
            guard let lift else { return }

            self.lift = nil
            if lift.original.map(\.id) == stack.items.map(\.id),
                lift.laidOut.map(\.id) == stack.items.map(\.id)
            {
                for entry in mountedEntries(in: lift.laidOut) {
                    shift(entry.node, to: 0)
                }
                goDown(lift.row)
            } else {
                landing = (lift.row, lift.top)
                stack.setItemsHoldingScroll(lift.original)
            }
            runFrames()
        }

        /// The stack's nodes are where a layout of its items put them: a lifted row's
        /// others are moved aside anew from there, and a row let go goes into its place.
        private func stackLaidOut() {
            if var lift {
                let isNewOrder = lift.laidOut.map(\.id) != stack.items.map(\.id)
                lift.laidOut = stack.items
                self.lift = lift
                follow(now: isNewOrder)
            } else if let landing {
                self.landing = nil
                // Laid out in the new order, the others are where they were drawn.
                for (_, shift) in shifts {
                    shift.node.appearance.offset = .zero
                }
                shifts = [:]
                for entry in mountedEntries(in: stack.items) where entry.node !== landing.row {
                    entry.node.appearance.offset = .zero
                }
                if let frame = (scroll ?? enclosingScroll)?.frame(of: landing.row) {
                    landing.row.appearance.offset = LayoutPoint(
                        x: 0,
                        y: landing.top - frame.origin.y
                    )
                }
                goDown(landing.row)
                runFrames()
            }
        }

        /// Moves `row` down into its place, lifted until it gets there.
        private func goDown(_ row: TableRow) {
            settlingRow = row
            shift(row, to: 0)
            if shifts[ObjectIdentifier(row)] == nil {
                settle(row)
            }
        }

        private func settle(_ row: TableRow) {
            shifts[ObjectIdentifier(row)] = nil
            row.appearance.offset = .zero
            row.lifted(false)
            if settlingRow === row {
                settlingRow = nil
            }
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func mountedChanged(_ isMounted: Bool) {
            // Out of the tree, nothing is drawn moving: the frames stop.
            if !isMounted {
                endMoving()
            }
        }

        /// Puts every node drawn moved back, at once: the rows changed under them.
        private func endMoving() {
            if let lift {
                self.lift = nil
                settle(lift.row)
            }
            if let landing {
                self.landing = nil
                settle(landing.row)
            }
            if let settlingRow {
                settle(settlingRow)
            }
            for (_, shift) in shifts {
                shift.node.appearance.offset = .zero
            }
            shifts = [:]
            runFrames()
        }

        /// Moves the row of `id` by `step` rows, over the edges of sections; returns whether
        /// it could.
        private func move(_ id: Item.ID, by step: Int) -> Bool {
            guard lift == nil, let from = position(of: id),
                let section = sections.firstIndex(where: { $0.id == from.section })
            else { return false }

            var to = TablePosition(section: from.section, index: from.index + step)
            if to.index < 0 {
                guard section > 0 else { return false }

                // Into the end of the section before.
                to = TablePosition(
                    section: sections[section - 1].id,
                    index: sections[section - 1].items.count
                )
            } else if to.index >= sections[section].items.count {
                guard section + 1 < sections.count else { return false }

                to = TablePosition(section: sections[section + 1].id, index: 0)
            }
            let move = TableMove(item: id, from: from, to: to)
            withAnimation(Table.makingRoom) {
                sections = applying(move, to: sections)
            }
            onMove?(move)
            return true
        }

        private func applying(_ move: TableMove<Item.ID>, to sections: [TableSection<Item>])
            -> [TableSection<Item>]
        {
            var sections = sections
            guard let from = sections.firstIndex(where: { $0.id == move.from.section }),
                let to = sections.firstIndex(where: { $0.id == move.to.section })
            else { return sections }

            let item = sections[from].items.remove(at: move.from.index)
            sections[to].items.insert(item, at: min(move.to.index, sections[to].items.count))
            return sections
        }

        private func position(of id: Item.ID) -> TablePosition? {
            for section in sections {
                if let index = section.items.firstIndex(where: { $0.id == id }) {
                    return TablePosition(section: section.id, index: index)
                }
            }
            return nil
        }

        /// Where the row of `id` goes by where `entries` have it: into the section of the
        /// title or the row before it.
        private func landing(of id: Item.ID, in entries: [Entry]) -> TablePosition? {
            guard let index = entries.firstIndex(where: { $0.id == .row(id) }) else { return nil }

            guard index > 0 else {
                return sections.first.map { TablePosition(section: $0.id, index: 0) }
            }
            switch entries[index - 1] {
            case let .header(section, _):
                return TablePosition(section: section, index: 0)
            case let .row(item):
                guard var before = position(of: item.id), let from = position(of: id) else {
                    return nil
                }

                // Among the items with the moved one taken out.
                if from.section == before.section, from.index < before.index {
                    before.index -= 1
                }
                return TablePosition(section: before.section, index: before.index + 1)
            }
        }

        /// The entries of `entries` whose nodes are mounted, with where they are in it, in
        /// that order. Found by what the nodes show: a layout solved in the background may
        /// have laid out other entries than those mounted.
        private func mountedEntries(in entries: [Entry]) -> [(index: Int, id: EntryID, node: Node)]
        {
            var indices: [EntryID: Int] = [:]
            for (index, entry) in entries.enumerated() {
                indices[entry.id] = index
            }
            return stack.subnodes.compactMap { node -> (Int, EntryID, Node)? in
                let id: EntryID
                if let row = node as? TableRow, let item = row.itemID?.base as? Item.ID {
                    id = .row(item)
                } else if let header = node as? SectionHeader, let section = header.sectionID {
                    id = .header(section)
                } else {
                    return nil
                }
                return indices[id].map { ($0, id, node) }
            }
            .sorted { $0.0 < $1.0 }
            .map { (index: $0.0, id: $0.1, node: $0.2) }
        }

        /// Seconds a node moved aside takes to go most of the way — two thirds of it.
        private static var shiftTime: Double { 0.05 }
        private static var makingRoom: Animation { .easeInOut(duration: 0.2) }
        /// How near the window's edge a lifted row scrolls it, and how fast at most.
        private static var autoscrollZone: Double { 60 }
        private static var autoscrollSpeed: Double { 600 }

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
        /// The id of the item the row shows.
        var itemID: AnyHashable?
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
            select: @escaping @MainActor () -> Void,
            editing: RowEditing? = nil
        ) {
            if cell.content !== content {
                cell.content = content
            }
            cell.editing = editing
            if let editing {
                // Edited, the row does not swipe: its buttons go, and a tap selects it.
                close()
                self.leading = []
                self.trailing = []
                dragAxis = nil
                cell.onTap = editing.marksSelection ? editing.toggle : nil
                cell.isFocusable = editing.marksSelection
                cell.accessibilityActions = moves(editing)
                return
            }
            dragAxis = .horizontal
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

        /// The actions that move an edited row by one, for assistive technologies.
        private func moves(_ editing: RowEditing) -> [AccessibilityAction] {
            guard let step = editing.step else { return [] }

            return [
                AccessibilityAction(name: "Move up") { step(-1) },
                AccessibilityAction(name: "Move down") { step(1) },
            ]
        }

        /// Shows the row lifted to be moved, over the others, or put down.
        func lifted(_ isLifted: Bool) {
            appearance.zIndex = isLifted ? 1 : 0
            cell.appearance.shadow = isLifted ? Shadow(opacity: 0.2, radius: 8, y: 2) : nil
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

    /// How a row of an edited table shows, and what its mark and handle do.
    struct RowEditing {
        /// Whether it shows a mark of its selection, which a tap changes.
        var marksSelection: Bool
        var isSelected: Bool
        var toggle: @MainActor () -> Void
        /// What a drag of its handle does; `nil` for a row that does not move.
        var drag: (@MainActor (Drag) -> Void)? = nil
        /// Moves it by that many rows; returns whether it could.
        var step: (@MainActor (Int) -> Bool)? = nil
    }

    /// What a table's frame timer calls on each frame: the table keeps it, the timer only
    /// points to it, so a table gone stops its timer.
    @MainActor
    final class FrameTicker {
        let tick: @MainActor () -> Void

        init(_ tick: @escaping @MainActor () -> Void) {
            self.tick = tick
        }
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
        /// How the row shows while its table is edited; `nil` while it is not.
        var editing: RowEditing? {
            didSet {
                mark.isSelected = editing?.isSelected ?? false
                handle.onDrag = editing?.drag
                if editing?.isSelected ?? false {
                    accessibility.traits.insert(.selected)
                } else {
                    accessibility.traits.remove(.selected)
                }
                appearance.background = background(pressed: false)
                setNeedsLayout()
            }
        }
        let mark = SelectionMark()
        let handle = MoveHandle()
        private let separator = Node()

        override init() {
            super.init()
            appearance.background = .white
            separator.appearance.background = Color(red: 0.85, green: 0.86, blue: 0.88)
            // One element, the content's text read as one, with the actions of the row.
            accessibility.isElement = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                if editing?.marksSelection ?? false { mark }
                if let content { content.flex(grow: 1, shrink: 1) }
                if editing?.drag != nil { handle }
                separator
                    .absolute(leading: 16, bottom: 0, trailing: 0)
                    .height(.points(0.5))
            }
        }

        override func pressChanged(_ isPressed: Bool) {
            appearance.background = background(pressed: isPressed)
        }

        private func background(pressed: Bool) -> Color {
            if pressed { return Color(red: 0.90, green: 0.91, blue: 0.93) }
            return editing?.isSelected ?? false ? Color(red: 0.91, green: 0.95, blue: 1) : .white
        }
    }

    /// The round mark at the leading side of an edited row: empty, or filled and checked
    /// when the row is selected. The row's element tells whether it is.
    @MainActor
    final class SelectionMark: Node {
        let circle = Circle()

        var isSelected: Bool {
            get { circle.isSelected }
            set { circle.isSelected = newValue }
        }

        override init() {
            super.init()
            accessibility.isElement = false
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                circle.size(width: 22, height: 22)
            }
            .alignItems(.center)
            .padding(top: 0, leading: 16, bottom: 0, trailing: 0)
        }

        @MainActor
        final class Circle: Node {
            private let check = Text("✓", style: TextStyle(size: 14, weight: .bold, color: .white))

            var isSelected = false {
                didSet {
                    guard isSelected != oldValue else { return }

                    look()
                    setNeedsLayout()
                }
            }

            override init() {
                super.init()
                check.accessibility.isElement = false
                appearance.cornerRadius = 11
                look()
            }

            private func look() {
                appearance.background = isSelected ? Color(red: 0, green: 0.48, blue: 1) : nil
                appearance.borderWidth = isSelected ? 0 : 1.5
                appearance.borderColor = Color(red: 0.78, green: 0.79, blue: 0.82)
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.row) {
                    if isSelected { check }
                }
                .justifyContent(.center)
                .alignItems(.center)
            }
        }
    }

    /// Three lines at the trailing side of an edited row that lift it to be dragged up or
    /// down. Taps on it do nothing, and it is not an element: the row's element moves it.
    @MainActor
    final class MoveHandle: Node {
        private let lines = (0..<3).map { _ in Node() }

        override init() {
            super.init()
            dragAxis = .vertical
            onTap = {}
            isFocusable = false
            accessibility.isElement = false
            for line in lines {
                line.appearance.background = Color(red: 0.70, green: 0.71, blue: 0.74)
                line.appearance.cornerRadius = 1
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for line in lines {
                    line.size(width: 20, height: 2)
                }
            }
            .justifyContent(.center)
            .gap(4)
            .padding(top: 0, leading: 12, bottom: 0, trailing: 16)
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
        /// The id of the section it is the title of.
        var sectionID: String?

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
