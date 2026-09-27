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
        func showing(_ message: Message) -> Line {
            accessibility.label = message.subject
            return self
        }

        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 44)) }
    }

    /// A 320-point table of thirty messages in two sections, with actions each side.
    @MainActor
    private final class Inbox {
        let lines = NodeCache<Int, Line> { _ in Line() }
        let table: Table<Message>
        let host: NodeHost
        var selected: [Int] = []
        var done: [String] = []

        init(direction: LayoutDirection = .leftToRight) {
            let lines = lines
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
#endif
