#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import Testing

    @testable import NodesRender

    private struct Message: Identifiable {
        let id: Int
        var subject: String { "Message \(id)" }
    }

    @MainActor
    private final class Line: Node {
        let height: Double

        init(height: Double = 44) {
            self.height = height
        }

        func showing(_ message: Message) -> Line {
            accessibility.label = message.subject
            return self
        }

        override var layoutContent: LeafContent? {
            .size(LayoutSize(width: 100, height: height))
        }
    }

    /// A 320-point table of thirty messages in two sections, with actions each side.
    @MainActor
    private final class Inbox {
        let lines: NodeCache<Int, Line>
        let table: Table<Message>
        let host: NodeHost
        var selected: [Int] = []
        var done: [String] = []

        init(direction: LayoutDirection = .leftToRight, rowHeight: Double = 44) {
            let lines = NodeCache<Int, Line> { _ in Line(height: rowHeight) }
            self.lines = lines
            table = Table { lines[$0.id].showing($0) }
            table.sections = [
                TableSection(id: "today", title: "Today", items: (0..<10).map(Message.init)),
                TableSection(id: "earlier", title: "Earlier", items: (10..<30).map(Message.init)),
            ]
            host = NodeHost(root: table, size: LayoutSize(width: 320, height: 400))
            host.direction = direction
            table.onSelect = { [unowned self] message in selected.append(message.id) }
            table.trailingActions = { [unowned self] message in
                [
                    SwipeAction("Delete", role: .destructive) {
                        self.done.append("Delete \(message.id)")
                    },
                    SwipeAction("Flag") { self.done.append("Flag \(message.id)") },
                ]
            }
            table.leadingActions = { [unowned self] message in
                [SwipeAction("Read") { self.done.append("Read \(message.id)") }]
            }
            host.layoutIfNeeded()
        }

        func row(_ id: Int) -> TableRow? {
            lines[id].supernode?.supernode as? TableRow
        }

        /// The middle of the row of message `id`, in the root's coordinates.
        func point(_ id: Int) -> LayoutPoint? {
            guard let row = row(id), let frame = table.scroll?.frame(of: row) else { return nil }

            return LayoutPoint(
                x: 160,
                y: frame.origin.y + 22 - (table.scroll?.contentOffset.y ?? 0)
            )
        }

        func swipe(_ id: Int, by x: Double, speed: Double = 0) throws {
            let at = try #require(point(id))
            #expect(host.dragBegan(at: at, along: .horizontal))
            host.dragMoved(by: LayoutPoint(x: x, y: 0))
            host.dragEnded(by: LayoutPoint(x: x, y: 0), velocity: LayoutPoint(x: speed, y: 0))
            host.layoutIfNeeded()
        }

        func tap(at point: LayoutPoint) {
            host.pointerDown(at: point)
            host.pointerUp(at: point)
        }

        /// The rows' ids in the order of the table's sections.
        var order: [[Int]] { table.sections.map { $0.items.map(\.id) } }

        /// The frame of the row of message `id` in the table's scroll, as laid out.
        func frame(_ id: Int) -> LayoutRect? {
            row(id).flatMap { table.scroll?.frame(of: $0) }
        }

        /// Where the row of message `id` shows in the window, moved as it is drawn.
        func shownTop(_ id: Int) -> Double? {
            guard let row = row(id), let frame = frame(id) else { return nil }

            return frame.origin.y + row.appearance.offset.y - (table.scroll?.contentOffset.y ?? 0)
        }

        /// Edits the table: rows move, and a tap selects them.
        func edit() {
            table.onMove = { [unowned self] move in moves.append(move) }
            table.allowsMultipleSelectionDuringEditing = true
            table.onSelectionChange = { [unowned self] selection in selections.append(selection) }
            table.isEditing = true
            host.layoutIfNeeded()
        }

        /// Lifts the row of message `id` by its handle.
        func lift(_ id: Int) throws {
            let frame = try #require(self.frame(id))
            let at = LayoutPoint(
                x: 320 - 10,
                y: frame.origin.y + frame.size.height / 2 - (table.scroll?.contentOffset.y ?? 0)
            )
            #expect(host.dragBegan(at: at, along: .vertical))
        }

        /// Drags the lifted row `y` points from where it was lifted, and lets the rows it
        /// moves aside get where they go.
        func drag(by y: Double) {
            host.dragMoved(by: LayoutPoint(x: 0, y: y))
            host.layoutIfNeeded()
            table.advance(by: 1)
        }

        /// Lets the lifted row go `y` points from where it was lifted, and lets it get to its
        /// place.
        func drop(at y: Double) {
            host.dragEnded(by: LayoutPoint(x: 0, y: y), velocity: .zero)
            host.layoutIfNeeded()
            table.advance(by: 1)
        }

        var moves: [TableMove<Int>] = []
        var selections: [Set<Int>] = []

        /// Points the trailing buttons of a row take.
        func trailingWidth(_ id: Int) -> Double {
            row(id)?.trailing.reduce(0) { $0 + $1.frame.size.width } ?? 0
        }
    }

    @Test @MainActor
    func aTableShowsItsSectionsAndATapSelectsARow() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }

        let labels = inbox.host.accessibilityItems().map(\.label)
        #expect(labels.prefix(3) == ["Today", "Message 0", "Message 1"])
        inbox.tap(at: try #require(inbox.point(2)))
        #expect(inbox.selected == [2])
    }

    @Test @MainActor
    func aSwipeTowardTheLeadingSideShowsTheTrailingActions() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }

        try inbox.swipe(1, by: -120)

        let row = try #require(inbox.row(1))
        #expect(inbox.trailingWidth(1) > 100)
        #expect(row.position == -inbox.trailingWidth(1))
        // The Delete button shows beside the cell, and a tap on it deletes.
        let delete = try #require(row.trailing.first)
        let deleteFrame = try #require(inbox.table.scroll?.frame(of: delete))
        let offset = inbox.table.scroll?.contentOffset.y ?? 0
        inbox.tap(
            at: LayoutPoint(x: deleteFrame.origin.x + 10, y: deleteFrame.origin.y + 10 - offset)
        )
        #expect(inbox.done == ["Delete 1"])
        #expect(row.position == 0)
    }

    @Test @MainActor
    func aShortSwipeGoesBackAndAFlickShowsTheActions() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }

        try inbox.swipe(1, by: -20)
        #expect(inbox.row(1)?.position == 0)

        try inbox.swipe(1, by: -20, speed: -800)
        #expect(inbox.row(1)?.position == -inbox.trailingWidth(1))
    }

    @Test @MainActor
    func aSwipeAcrossMostOfTheRowDoesTheFirstAction() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }

        try inbox.swipe(3, by: -250)

        #expect(inbox.done == ["Delete 3"])
    }

    @Test @MainActor
    func aSwipeTheOtherWayShowsTheLeadingActions() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }

        try inbox.swipe(1, by: 100)

        let row = try #require(inbox.row(1))
        let width = row.leading.reduce(0) { $0 + $1.frame.size.width }
        #expect(row.position == width)
    }

    @Test @MainActor
    func fromTheRightASwipeTowardTheLeftShowsTheLeadingActions() throws {
        let inbox = Inbox(direction: .rightToLeft)
        defer { inbox.host.detach() }

        // Leading is on the right: moving the cell left is toward the trailing side.
        try inbox.swipe(1, by: -100)

        let row = try #require(inbox.row(1))
        #expect(row.position > 0)
        #expect(row.cell.appearance.offset.x < 0)
    }

    @Test @MainActor
    func oneRowShowsItsActionsAtATimeAndATapPutsItBack() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        try inbox.swipe(1, by: -120)

        try inbox.swipe(2, by: -120)
        #expect(inbox.row(1)?.position == 0)
        #expect(inbox.row(2)?.position != 0)

        // A tap on the cell puts it back rather than selecting it.
        inbox.tap(at: LayoutPoint(x: 20, y: try #require(inbox.point(2)).y))
        #expect(inbox.row(2)?.position == 0)
        #expect(inbox.selected.isEmpty)
    }

    @Test @MainActor
    func scrollingPutsTheRowBack() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        try inbox.swipe(1, by: -120)

        inbox.table.scroll?.contentOffset = LayoutPoint(x: 0, y: 100)

        #expect(inbox.row(1)?.position == 0)
    }

    @Test @MainActor
    func voiceOverOffersARowsActions() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }

        let items = inbox.host.accessibilityItems()
        let row = try #require(items.first { $0.label == "Message 1" })
        #expect(row.actions == ["Read", "Delete", "Flag"])
        // The buttons behind the cell are not read on their own.
        #expect(!items.contains { $0.label == "Delete" })
        #expect(inbox.host.performAccessibilityAction(2, of: row.node))
        #expect(inbox.done == ["Flag 1"])
    }

    @Test @MainActor
    func aRowMovesOnlyTowardActionsItHasAndNoFurtherThanItsWidth() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.table.leadingActions = nil
        inbox.host.layoutIfNeeded()
        let at = try #require(inbox.point(1))
        let row = try #require(inbox.row(1))

        inbox.host.dragBegan(at: at, along: .horizontal)
        inbox.host.dragMoved(by: LayoutPoint(x: 80, y: 0))
        #expect(row.position == 0)
        inbox.host.dragMoved(by: LayoutPoint(x: -500, y: 0))
        #expect(row.position == -320)
        inbox.host.dragCancelled()
    }

    @Test @MainActor
    func theRemoteGoesToRowsOnlyWhenTheySelectAndNeverToTheButtons() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        let row = try #require(inbox.row(1))
        #expect(row.cell.isFocusable == true)
        #expect(row.trailing.allSatisfy { $0.isFocusable == false })

        inbox.table.onSelect = nil
        inbox.host.layoutIfNeeded()
        #expect(row.cell.isFocusable == false)
    }

    // MARK: - Editing

    @Test @MainActor
    func anEditedTableMarksRowsAndATapSelectsThem() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        let row = try #require(inbox.row(2))
        #expect(row.cell.mark.isMounted)
        #expect(row.cell.handle.isMounted)

        inbox.tap(at: try #require(inbox.point(2)))
        // The mark shows it before a layout does.
        #expect(row.cell.mark.isSelected)
        inbox.host.layoutIfNeeded()
        #expect(inbox.table.selection == [2])
        inbox.tap(at: try #require(inbox.point(5)))
        inbox.tap(at: try #require(inbox.point(2)))
        inbox.host.layoutIfNeeded()
        #expect(inbox.selections == [[2], [2, 5], [5]])
        // A tap selects, and does not do what it does out of editing.
        #expect(inbox.selected.isEmpty)
        let items = inbox.host.accessibilityItems()
        #expect(items.first { $0.label == "Message 5" }?.traits.contains(.selected) == true)
        #expect(items.first { $0.label == "Message 2" }?.traits.contains(.selected) == false)

        inbox.table.isEditing = false
        inbox.host.layoutIfNeeded()
        #expect(!row.cell.mark.isMounted)
        #expect(!row.cell.handle.isMounted)
        inbox.tap(at: try #require(inbox.point(2)))
        #expect(inbox.selected == [2])
    }

    @Test @MainActor
    func anEditedRowDoesNotSwipeAndOffersToMoveInstead() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        try inbox.swipe(1, by: -120)
        inbox.edit()

        // The row that showed its actions is put back, and none swipes.
        #expect(inbox.row(1)?.position == 0)
        #expect(!inbox.host.dragBegan(at: try #require(inbox.point(3)), along: .horizontal))
        let items = inbox.host.accessibilityItems()
        #expect(items.first { $0.label == "Message 3" }?.actions == ["Move up", "Move down"])
    }

    @Test @MainActor
    func aRowDraggedByItsHandleMovesAmongTheOthers() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        let start = try #require(inbox.shownTop(1))
        let second = try #require(inbox.shownTop(2))

        try inbox.lift(1)
        #expect(inbox.row(1)?.appearance.zIndex == 1)
        #expect(inbox.row(1)?.supernode?.subnodesInDrawingOrder.last === inbox.row(1))
        // Its middle is past the middles of the next two rows, where they are.
        inbox.drag(by: 100)

        #expect(inbox.shownTop(1) == start + 100)
        // Those two moved up to make room; the third after it did not.
        #expect(inbox.shownTop(2) == start)
        #expect(inbox.shownTop(3) == start + 44)
        #expect(inbox.shownTop(4) == start + 132)
        #expect(inbox.shownTop(5) == second + 3 * 44)
        #expect(inbox.moves.isEmpty)

        inbox.drop(at: 100)
        #expect(inbox.order[0].prefix(6) == [0, 2, 3, 1, 4, 5])
        #expect(
            inbox.moves == [
                TableMove(
                    item: 1,
                    from: TablePosition(section: "today", index: 1),
                    to: TablePosition(section: "today", index: 3)
                )
            ]
        )
        // It settles into its place.
        #expect(inbox.row(1)?.appearance.offset == .zero)
        #expect(inbox.row(1)?.appearance.zIndex == 0)
        #expect(inbox.shownTop(1) == start + 88)
    }

    @Test @MainActor
    func aRowGoesPastANeighborOnlyOnceItsMiddleCrossesTheNeighbors() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        let start = try #require(inbox.shownTop(2))

        try inbox.lift(1)
        // A point down, and up to just short of the next row's middle, 44 below its own:
        // nothing makes room.
        inbox.drag(by: 1)
        #expect(inbox.shownTop(2) == start)
        inbox.drag(by: 43)
        #expect(inbox.shownTop(2) == start)
        // Past it: the next row moves up.
        inbox.drag(by: 45)
        #expect(inbox.shownTop(2) == start - 44)
        inbox.drop(at: 45)
        #expect(inbox.order[0].prefix(3) == [0, 2, 1])
    }

    @Test @MainActor
    func aRowDraggedAboveATitleGoesToTheEndOfTheSectionBefore() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        inbox.table.scroll?.contentOffset = LayoutPoint(x: 0, y: 300)
        inbox.host.layoutIfNeeded()
        let row = try #require(inbox.frame(10))
        let title = try #require(inbox.frame(9)).origin.y + 44
        // The row's middle goes just above the middle of the title over it.
        let middle = (title + row.origin.y) / 2 - 2
        let by = middle - (row.origin.y + 22)

        try inbox.lift(10)
        inbox.drag(by: by)
        inbox.drop(at: by)

        #expect(inbox.order[0].last == 10)
        #expect(inbox.order[1].first == 11)
        #expect(inbox.moves.map(\.to) == [TablePosition(section: "today", index: 10)])
    }

    @Test @MainActor
    func aRowDraggedBelowATitleGoesToTheStartOfItsSection() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        inbox.table.scroll?.contentOffset = LayoutPoint(x: 0, y: 300)
        inbox.host.layoutIfNeeded()
        let row = try #require(inbox.frame(9))
        let first = try #require(inbox.frame(10))
        // The row's middle goes just below the title's, where the title is.
        let title = first.origin.y - (row.origin.y + 44)
        let middle = row.origin.y + 44 + title / 2 + 5
        let by = middle - (row.origin.y + 22)

        try inbox.lift(9)
        inbox.drag(by: by)
        inbox.drop(at: by)

        #expect(inbox.order[1].prefix(2) == [9, 10])
        #expect(
            inbox.moves.map(\.to) == [TablePosition(section: "earlier", index: 0)]
        )
    }

    @Test @MainActor
    func aRowGoesNoHigherThanTheFirstTitle() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()

        try inbox.lift(1)
        inbox.drag(by: -300)
        inbox.drop(at: -300)

        #expect(inbox.order[0].prefix(2) == [1, 0])
        #expect(inbox.moves.map(\.to) == [TablePosition(section: "today", index: 0)])
    }

    @Test @MainActor
    func aRowHeldNearTheEdgeScrollsTheTableAndStaysUnderTheDrag() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        let scroll = try #require(inbox.table.scroll)

        try inbox.lift(2)
        let start = try #require(inbox.shownTop(2))
        // The row's bottom 20 points above the window's: in the edge's 60.
        let by = 400 - 20 - 44 - start
        inbox.host.dragMoved(by: LayoutPoint(x: 0, y: by))
        inbox.host.layoutIfNeeded()
        for _ in 0..<10 {
            inbox.table.advance(by: 0.1)
            inbox.host.layoutIfNeeded()
        }

        // Two thirds of the way into the edge: two thirds of 600 points a second, for a
        // second.
        #expect(abs(scroll.contentOffset.y - 400) < 1)
        #expect(abs((inbox.shownTop(2) ?? 0) - (start + by)) < 0.5)
        inbox.drop(at: by)
        let moved = try #require(inbox.moves.first)
        #expect(moved.item == 2)
        #expect(moved.to.section == "earlier")
    }

    @Test @MainActor
    func aLiftTheSystemTakesAwayPutsTheRowBack() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        let start = try #require(inbox.shownTop(1))

        try inbox.lift(1)
        inbox.drag(by: 100)
        inbox.host.dragCancelled()
        inbox.host.layoutIfNeeded()
        inbox.table.advance(by: 1)

        #expect(inbox.order[0].prefix(3) == [0, 1, 2])
        #expect(inbox.moves.isEmpty)
        #expect(inbox.shownTop(1) == start)
        #expect(inbox.row(1)?.appearance.zIndex == 0)
    }

    @Test @MainActor
    func endingTheEditingPutsALiftedRowWhereItIs() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()

        try inbox.lift(1)
        inbox.drag(by: 50)
        inbox.table.isEditing = false
        inbox.host.layoutIfNeeded()
        inbox.table.advance(by: 1)

        #expect(inbox.order[0].prefix(3) == [0, 2, 1])
        #expect(inbox.row(1)?.appearance.offset == .zero)
        #expect(inbox.moves.count == 1)
    }

    @Test @MainActor
    func voiceOverMovesARowByOneAcrossSections() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        func act(_ label: String, _ action: Int) -> Bool {
            guard let item = inbox.host.accessibilityItems().first(where: { $0.label == label })
            else { return false }

            let done = inbox.host.performAccessibilityAction(action, of: item.node)
            inbox.host.layoutIfNeeded()
            return done
        }

        #expect(act("Message 1", 1))
        #expect(inbox.order[0].prefix(3) == [0, 2, 1])
        #expect(!act("Message 0", 0))
        inbox.table.scroll?.contentOffset = LayoutPoint(x: 0, y: 300)
        inbox.host.layoutIfNeeded()
        #expect(act("Message 10", 0))
        #expect(inbox.order[0].last == 10)
        #expect(
            inbox.moves.map(\.to) == [
                TablePosition(section: "today", index: 2),
                TablePosition(section: "today", index: 10),
            ]
        )
    }

    @Test @MainActor
    func aRowThatDoesNotMoveHasNoHandle() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.table.canMove = { $0.id != 1 }
        inbox.edit()

        #expect(inbox.row(1)?.cell.handle.isMounted == false)
        #expect(inbox.row(2)?.cell.handle.isMounted == true)
        let items = inbox.host.accessibilityItems()
        #expect(items.first { $0.label == "Message 1" }?.actions == [])
    }

    @Test @MainActor
    func itemsThatLeaveTheTableLeaveTheSelection() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        inbox.table.selection = [1, 2]

        inbox.table.sections[0].items.removeAll { $0.id == 1 }

        #expect(inbox.table.selection == [2])
        #expect(inbox.selections == [[2]])
    }
#endif

#if canImport(CoreText)
    @Test @MainActor
    func aRowDraggedWhileLayoutsAreSolvedInTheBackgroundMovesWhereItIsLetGo() async throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        inbox.host.solvesInBackground = true

        try inbox.lift(0)
        // Each step asks for a layout the next one does not wait for.
        for step in 1...5 {
            inbox.drag(by: Double(step) * 30)
        }
        await inbox.host.layoutFinished()
        inbox.drag(by: 150)
        await inbox.host.layoutFinished()
        inbox.drop(at: 150)
        await inbox.host.layoutFinished()
        inbox.table.advance(by: 1)
        #expect(inbox.row(0)?.appearance.offset == .zero)

        // Its middle went 150 points down, past the middles of the next three rows.
        #expect(inbox.order[0].prefix(6) == [1, 2, 3, 0, 4, 5])
        #expect(inbox.moves.map(\.to) == [TablePosition(section: "today", index: 3)])
    }
#endif

#if canImport(CoreText)
    /// A 300-point header, then a table of thirty messages without a scroll of its own, in
    /// a 400-point scroll.
    @MainActor
    private final class Page: Node {
        let lines = NodeCache<Int, Line> { _ in Line() }
        let header = Line()
        let table: Table<Message>
        let scroll: Scroll
        var moves: [TableMove<Int>] = []

        override init() {
            let lines = lines
            table = Table(scrolls: false) { lines[$0.id].showing($0) }
            table.sections = [TableSection(id: "all", items: (0..<30).map(Message.init))]
            scroll = Scroll(.vertical)
            super.init()
            scroll.content = Body(header: header, table: table)
            table.onMove = { [unowned self] move in moves.append(move) }
            table.isEditing = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }

        final class Body: Node {
            let header: Line
            let table: Table<Message>

            init(header: Line, table: Table<Message>) {
                self.header = header
                self.table = table
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) {
                    header.height(.points(300))
                    table
                }
            }
        }

        func row(_ id: Int) -> TableRow? {
            lines[id].supernode?.supernode as? TableRow
        }

        /// Where the row of message `id` shows in the window, moved as it is drawn.
        func shownTop(_ id: Int) -> Double? {
            guard let row = row(id), let frame = scroll.frame(of: row) else { return nil }

            return frame.origin.y + row.appearance.offset.y - scroll.contentOffset.y
        }
    }

    @Test @MainActor
    func aRowHeldNearTheEdgeScrollsTheScrollAroundTheTable() throws {
        let page = Page()
        let host = NodeHost(root: page, size: LayoutSize(width: 320, height: 400))
        host.layoutIfNeeded()
        defer { host.detach() }
        page.scroll.contentOffset = LayoutPoint(x: 0, y: 250)
        host.layoutIfNeeded()

        let start = try #require(page.shownTop(1))
        #expect(host.dragBegan(at: LayoutPoint(x: 310, y: start + 22), along: .vertical))
        let by = 400 - 20 - 44 - start
        host.dragMoved(by: LayoutPoint(x: 0, y: by))
        host.layoutIfNeeded()
        for _ in 0..<10 {
            page.table.advance(by: 0.1)
            host.layoutIfNeeded()
        }

        #expect(abs(page.scroll.contentOffset.y - 650) < 1)
        #expect(abs((page.shownTop(1) ?? 0) - (start + by)) < 0.5)
        // Back up the window by 100: it goes with the drag.
        host.dragMoved(by: LayoutPoint(x: 0, y: by - 100))
        host.layoutIfNeeded()
        #expect(abs((page.shownTop(1) ?? 0) - (start + by - 100)) < 0.5)
        host.dragEnded(by: LayoutPoint(x: 0, y: by - 100), velocity: .zero)
        host.layoutIfNeeded()
        page.table.advance(by: 1)

        // Where it was let go: the rows at its middle then are before it.
        let top = start + by - 100 + page.scroll.contentOffset.y
        let index = try #require(page.moves.first?.to.index)
        let frame = try #require(page.row(1).flatMap { page.scroll.frame(of: $0) })
        #expect(abs(frame.origin.y - top) < 44)
        #expect(index > 8)
    }
#endif

#if canImport(CoreText)
    @Test @MainActor
    func aRowHeldNearTheEdgeStaysUnderTheDragWhileLayoutsLag() async throws {
        let page = Page()
        let host = NodeHost(root: page, size: LayoutSize(width: 320, height: 400))
        host.layoutIfNeeded()
        defer { host.detach() }
        page.scroll.contentOffset = LayoutPoint(x: 0, y: 250)
        host.layoutIfNeeded()
        host.solvesInBackground = true

        let start = try #require(page.shownTop(1))
        #expect(host.dragBegan(at: LayoutPoint(x: 310, y: start + 22), along: .vertical))
        let by = 400 - 20 - 44 - start
        host.dragMoved(by: LayoutPoint(x: 0, y: by))
        // Frames go by, and the layouts they ask for are solved in the background: the row
        // is under the drag on every one of them, laid out anew or not.
        for frame in 0..<30 {
            page.table.advance(by: 1 / 30)
            host.layoutIfNeeded()
            if frame % 10 == 9 {
                await host.layoutFinished()
            }
            #expect(abs((page.shownTop(1) ?? 0) - (start + by)) < 0.5, "frame \(frame)")
        }
        await host.layoutFinished()
        host.dragEnded(by: LayoutPoint(x: 0, y: by), velocity: .zero)
        host.layoutIfNeeded()
        await host.layoutFinished()
        page.table.advance(by: 1)

        // It went down into the place where it was let go.
        let top = start + by + page.scroll.contentOffset.y
        let frame = try #require(page.row(1).flatMap { page.scroll.frame(of: $0) })
        #expect(abs(frame.origin.y - top) < 44)
        #expect(page.row(1)?.appearance.offset == .zero)
        #expect(page.row(1)?.appearance.zIndex == 0)
    }
#endif

#if canImport(CoreText)
    @Test @MainActor
    func aShortRowGoesNoHigherThanTheFirstTitleThoughItsMiddleIsAboveTheTitles() throws {
        // Rows 20 long, under a title longer than that.
        let inbox = Inbox(rowHeight: 20)
        defer { inbox.host.detach() }
        inbox.edit()

        try inbox.lift(1)
        inbox.drag(by: -300)
        inbox.drop(at: -300)

        #expect(inbox.order[0].prefix(2) == [1, 0])
        let labels = inbox.host.accessibilityItems().map(\.label)
        #expect(labels.prefix(3) == ["Today", "Message 1", "Message 0"])
    }

    @Test @MainActor
    func aRowHeldNearTheTopScrollsTheTableBack() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        let scroll = try #require(inbox.table.scroll)
        scroll.contentOffset = LayoutPoint(x: 0, y: 600)
        inbox.host.layoutIfNeeded()
        let id = try #require((0..<30).first { (inbox.shownTop($0) ?? -1) > 150 })

        try inbox.lift(id)
        let start = try #require(inbox.shownTop(id))
        // The row's top 20 points under the window's: in the edge's 60.
        let by = 20 - start
        inbox.host.dragMoved(by: LayoutPoint(x: 0, y: by))
        inbox.host.layoutIfNeeded()
        for _ in 0..<10 {
            inbox.table.advance(by: 0.1)
            inbox.host.layoutIfNeeded()
        }

        // Two thirds of the way into the edge: 400 points a second, for a second.
        #expect(abs(scroll.contentOffset.y - 200) < 1)
        #expect(abs((inbox.shownTop(id) ?? 0) - 20) < 0.5)
        inbox.drop(at: by)
        #expect((inbox.moves.first?.to.index ?? 99) < (inbox.moves.first?.from.index ?? 0))
    }

    @Test @MainActor
    func anEditedTableWithoutSelectionTakesNoTaps() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        inbox.table.allowsMultipleSelectionDuringEditing = false
        inbox.host.layoutIfNeeded()

        // Nothing there takes a press: the row is not shown pressed.
        #expect(!inbox.host.pointerDown(at: try #require(inbox.point(2))))
        inbox.tap(at: try #require(inbox.point(2)))

        #expect(inbox.table.selection.isEmpty)
        #expect(inbox.selected.isEmpty)
        #expect(inbox.row(2)?.cell.mark.isMounted == false)
    }

    @Test @MainActor
    func newSectionsPutALiftedRowDown() throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()

        try inbox.lift(1)
        inbox.drag(by: 100)
        inbox.table.sections[0].items.removeAll { $0.id == 5 }
        inbox.host.layoutIfNeeded()

        #expect(inbox.row(1)?.appearance.offset == .zero)
        #expect(inbox.row(2)?.appearance.offset == .zero)
        #expect(inbox.row(1)?.appearance.zIndex == 0)
        // What the drag does after is nothing.
        inbox.drop(at: 100)
        #expect(inbox.moves.isEmpty)
        #expect(inbox.order[0].prefix(3) == [0, 1, 2])
    }

    @Test @MainActor
    func aRowHeldFarFromItsPlaceStaysLaidOutUnderTheDrag() throws {
        let page = Page()
        let host = NodeHost(root: page, size: LayoutSize(width: 320, height: 400))
        host.layoutIfNeeded()
        defer { host.detach() }
        page.scroll.contentOffset = LayoutPoint(x: 0, y: 250)
        host.layoutIfNeeded()

        let start = try #require(page.shownTop(1))
        #expect(host.dragBegan(at: LayoutPoint(x: 310, y: start + 22), along: .vertical))
        // At the very edge: 600 points a second.
        let by = 400 - 44 - start
        host.dragMoved(by: LayoutPoint(x: 0, y: by))
        host.layoutIfNeeded()
        for _ in 0..<20 {
            page.table.advance(by: 0.1)
            host.layoutIfNeeded()
        }

        // Far past the part of the list laid out around where it was, it is still there.
        #expect(page.row(1)?.isMounted == true)
        #expect(abs((page.shownTop(1) ?? 0) - (start + by)) < 0.5)
        host.dragEnded(by: LayoutPoint(x: 0, y: by), velocity: .zero)
        host.layoutIfNeeded()
        page.table.advance(by: 1)
        #expect((page.moves.first?.to.index ?? 0) > 20)
    }

    @Test @MainActor
    func aLayoutOfTheOrderBeforeTheDropLeavesTheRowWhereItWasLetGo() async throws {
        let inbox = Inbox()
        defer { inbox.host.detach() }
        inbox.edit()
        inbox.host.solvesInBackground = true
        let start = try #require(inbox.shownTop(1))

        try inbox.lift(1)
        inbox.drag(by: 100)
        await inbox.host.layoutFinished()
        // A layout of the order before the drop is on its way when the row is let go.
        inbox.host.setNeedsLayout()
        inbox.host.layoutIfNeeded()
        inbox.host.dragEnded(by: LayoutPoint(x: 0, y: 100), velocity: .zero)
        await inbox.host.layoutFinished()
        inbox.table.advance(by: 1)

        #expect(inbox.shownTop(1) == start + 100)
        inbox.host.layoutIfNeeded()
        await inbox.host.layoutFinished()
        inbox.table.advance(by: 1)
        // Laid out in its place, 88 points down, it went down into it.
        #expect(inbox.shownTop(1) == start + 88)
        #expect(inbox.row(1)?.appearance.offset == .zero)
    }
#endif
