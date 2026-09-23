import Foundation
import TrellisCore

/// R12c consumer: a `TableNode` inbox — sections with headers, separators, single selection,
/// trailing Archive/Delete and leading Pin actions revealed by swiping a row (full swipe runs
/// the first action), the same actions offered to VoiceOver as custom actions. The status line
/// (accessibility identifier `r12c-status`) reports the last action and the row count.
@MainActor enum S37 {
    struct Message: Sendable, Equatable {
        let sender: String
        let subject: String
    }

    @MainActor
    final class MessageProvider: ItemProvider {
        func makeNode(for item: Message, id: Int) -> Node {
            let row = Node()
            row.style {
                $0.flexDirection = .column
                $0.gap = 2
                $0.padding = DirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            }
            let sender = TextNode(
                text: item.sender,
                textStyle: TextStyle(
                    pointSize: 15,
                    weight: .semibold,
                    color: Palette.theme.colors.text
                )
            )
            let subject = TextNode(
                text: item.subject,
                textStyle: TextStyle(pointSize: 13, color: Palette.theme.colors.textSecondary)
            )
            row.addSubnode(sender)
            row.addSubnode(subject)
            row.accessibility.label = "\(item.sender), \(item.subject)"
            row.accessibility.identifier = "message-\(id)"
            return row
        }

        func update(_ node: Node, with item: Message, id: Int) {}
    }

    @MainActor
    final class Mailbox {
        let source: StateSubject<CollectionSnapshot<Int, Message>>
        var status = "ready"
        var onChange: (@MainActor () -> Void)?
        private var pinned: Set<Int> = []

        init() {
            let senders = [
                "Ada", "Grace", "Linus", "Margaret", "Barbara", "Ken", "Radia", "Dennis",
            ]
            func messages(_ ids: Range<Int>) -> [CollectionItem<Int, Message>] {
                ids.map {
                    CollectionItem(
                        id: $0,
                        value: Message(
                            sender: senders[$0 % senders.count],
                            subject: "Message \($0)"
                        )
                    )
                }
            }
            source = StateSubject(
                CollectionSnapshot(
                    dataKey: "inbox",
                    revision: 1,
                    sections: [
                        CollectionSection(id: "Today", items: messages(0..<6)),
                        CollectionSection(id: "Yesterday", items: messages(6..<14)),
                        CollectionSection(id: "Earlier", items: messages(14..<40)),
                    ]
                )
            )
        }

        var count: Int { source.current.count }

        func remove(_ id: Int, reason: String) {
            let current = source.current
            source.send(
                CollectionSnapshot(
                    dataKey: current.dataKey,
                    revision: current.revision + 1,
                    sections: current.sections.map {
                        CollectionSection(id: $0.id, items: $0.items.filter { $0.id != id })
                    }
                )
            )
            status = "\(reason) \(id)"
            onChange?()
        }

        func trailing(_ id: Int) -> [RowAction<Int>] {
            [
                RowAction(id: "archive", title: "Archive") { [weak self] id in
                    self?.remove(id, reason: "archived")
                    return .completed
                },
                RowAction(id: "delete", title: "Delete", style: .destructive) { [weak self] id in
                    self?.remove(id, reason: "deleted")
                    return .completed
                },
            ]
        }

        func leading(_ id: Int) -> [RowAction<Int>] {
            [
                RowAction(id: "pin", title: pinned.contains(id) ? "Unpin" : "Pin") {
                    [weak self] id in
                    guard let self else { return .completed }

                    if self.pinned.remove(id) == nil { self.pinned.insert(id) }
                    self.status = "pinned \(id)"
                    self.onChange?()
                    return .completed
                }
            ]
        }
    }

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.flexDirection = .column; $0.gap = 8
        }

        let status = TextNode(text: "rows=40 last=ready", textStyle: TextStyle(pointSize: 13))
        status.accessibility.identifier = "r12c-status"
        status.accessibility.label = "Inbox status"
        status.style.flexShrink = 0
        root.addSubnode(status)

        let mailbox = Mailbox()
        var style = LayoutStyle()
        style.width = .fraction(1)
        style.flexGrow = 1
        style.flexShrink = 1
        let table = TableNode(
            source: mailbox.source,
            provider: MessageProvider(),
            estimatedRowHeight: 58,
            style: style
        )
        table.tableAppearance = TableAppearance(
            rowBackground: Palette.card,
            selectedBackground: Palette.cardLight,
            separatorColor: Palette.border,
            separatorInset: 16
        )
        table.sectionHeader = { id in
            let header = TextNode(
                text: id.uppercased(),
                textStyle: TextStyle(
                    pointSize: 12,
                    weight: .semibold,
                    color: Palette.theme.colors.textSecondary
                )
            )
            header.style.padding = DirectionalEdgeInsets(
                top: 14,
                leading: 16,
                bottom: 6,
                trailing: 16
            )
            header.accessibility.role = .header
            header.accessibility.identifier = "section-\(id)"
            return header
        }
        // The table owns the mailbox through its action closures; the mailbox holds nothing back.
        table.trailingActions = { mailbox.trailing($0) }
        table.leadingActions = { mailbox.leading($0) }
        let report: @MainActor () -> Void = { [weak status, weak mailbox, weak table] in
            guard let status, let mailbox, let table else { return }

            let open = table.swipe.openRow.map(String.init) ?? "none"
            let text =
                "rows=\(mailbox.count) last=\(mailbox.status) open=\(open) "
                + "revealed=\(Int(table.swipe.revealed)) phase=\(table.swipe.phase)"
            status.text = text
            status.accessibility.value = text
        }
        mailbox.onChange = report
        table.events.onSelect = { id in
            mailbox.status = "selected \(id)"
            report()
        }
        report()
        // Swipe state is reported too, for UI tests and manual checks.
        Task { @MainActor [weak table] in
            while table != nil {
                try? await Task.sleep(for: .milliseconds(100))
                report()
            }
        }
        root.addSubnode(table)

        return ScenarioNodes.instance(
            .s37,
            root: root,
            inputs: "TableNode, 3 sections, 40 messages, Pin / Archive / Delete swipe actions",
            expected: "swipe reveals actions; Delete removes only that row; taps select",
            paths: ["status", "table"]
        )
    }
}
