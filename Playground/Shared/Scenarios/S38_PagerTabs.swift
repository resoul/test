import Foundation
import TrellisCore

/// R13 consumer: `TabsNode` + `PagerNode` with five pages — three simple pages, a `ListNode`
/// feed and a `TableNode` with swipe actions (disabled by the pager's context). Pages are built
/// by factories on demand; only the selected page and its neighbours are mounted. The status
/// line (accessibility identifier `r13-status`) reports selection, progress, mounted pages,
/// factory calls and the feed's reading position.
@MainActor enum S38 {
    struct Row: Sendable, Equatable {
        let title: String
    }

    @MainActor
    final class RowProvider: ItemProvider {
        func makeNode(for item: Row, id: Int) -> Node {
            let row = Node()
            row.style {
                $0.padding = DirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            }
            row.appearance.background = .color(
                id.isMultiple(of: 2) ? Palette.card : Palette.cardLight
            )
            let title = TextNode(
                text: item.title,
                textStyle: TextStyle(pointSize: 15, color: Palette.theme.colors.text)
            )
            row.addSubnode(title)
            row.accessibility.isElement = true
            row.accessibility.label = item.title
            row.accessibility.identifier = "feed-\(id)"
            return row
        }

        func update(_ node: Node, with item: Row, id: Int) {}
    }

    /// Data outlives the page UI: factories only build nodes.
    @MainActor
    final class Model {
        let feed = StateSubject(
            CollectionSnapshot(
                dataKey: "feed",
                revision: 1,
                items: (0..<200).map { CollectionItem(id: $0, value: Row(title: "Post \($0)")) }
            )
        )
        let mail = StateSubject(
            CollectionSnapshot(
                dataKey: "mail",
                revision: 1,
                items: (0..<40).map { CollectionItem(id: $0, value: Row(title: "Mail \($0)")) }
            )
        )
        var made: [String: Int] = [:]
        var feedPosition = "none"
        var lastAction = "none"
    }

    static func page(_ id: String, color: ThemeColor) -> Node {
        let page = Node()
        page.style {
            $0.justifyContent = .center
            $0.alignItems = .center
        }
        page.appearance.background = .color(color)
        let label = TextNode(
            text: "Page \(id.uppercased())",
            textStyle: TextStyle(pointSize: 28, weight: .semibold, color: Palette.theme.colors.text)
        )
        page.addSubnode(label)
        page.accessibility.isElement = true
        page.accessibility.label = "Page \(id.uppercased())"
        page.accessibility.identifier = "page-\(id)"
        return page
    }

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.flexDirection = .column; $0.gap = 8
        }

        let status = TextNode(text: "selected=a", textStyle: TextStyle(pointSize: 12))
        status.accessibility.identifier = "r13-status"
        status.accessibility.label = "Pager status"
        status.style.flexShrink = 0
        root.addSubnode(status)

        let model = Model()
        func counted(_ id: String, _ build: @escaping @MainActor () -> Node) -> Tab<String> {
            Tab(id: id, title: id == "feed" ? "Feed" : id == "mail" ? "Mail" : id.uppercased()) {
                model.made[id, default: 0] += 1
                return build()
            }
        }
        var style = LayoutStyle()
        style.width = .fraction(1)
        style.flexGrow = 1
        style.flexShrink = 1
        let pager = PagerNode(
            tabs: [
                counted("a") { page("a", color: Palette.card) },
                counted("feed") {
                    let list = ListNode(source: model.feed, provider: RowProvider())
                    list.style.flexGrow = 1
                    return list
                },
                counted("b") { page("b", color: Palette.cardLight) },
                counted("mail") {
                    let table = TableNode(source: model.mail, provider: RowProvider())
                    table.trailingActions = { _ in
                        [
                            RowAction(id: "archive", title: "Archive") { id in
                                model.lastAction = "archived \(id)"
                                return .completed
                            }
                        ]
                    }
                    table.style.flexGrow = 1
                    return table
                },
                counted("c") { page("c", color: Palette.card) },
            ],
            style: style
        )
        let tabs = TabsNode(pager: pager)
        root.addSubnode(tabs)
        root.addSubnode(pager)

        let report: @MainActor () -> Void = { [weak status, weak pager] in
            guard let status, let pager else { return }

            if let list = pager.page(for: "feed") as? ListNode<RowProvider>,
                let position = list.pagePosition
            {
                model.feedPosition = "\(position.itemID)@\(Int(position.offsetFromTop.rounded()))"
            }
            let progress = pager.progress
            let made = model.made.keys.sorted().map { "\($0):\(model.made[$0]!)" }.joined(
                separator: ","
            )
            let text =
                "selected=\(pager.selection ?? "-") "
                + "progress=\(progress.from ?? "-")>\(progress.to ?? "-") "
                + "f=\(String(format: "%.2f", progress.fraction)) "
                + "settled=\(progress.settled ?? "-") "
                + "mounted=\(pager.mountedIDs.joined(separator: ",")) made=\(made) "
                + "feed=\(model.feedPosition) action=\(model.lastAction)"
            status.text = text
            status.accessibility.value = text
        }
        pager.onProgressChange = { _, _ in report() }
        report()
        Task { @MainActor [weak pager] in
            while pager != nil {
                try? await Task.sleep(for: .milliseconds(100))
                report()
            }
        }

        return ScenarioNodes.instance(
            .s38,
            root: root,
            inputs: "TabsNode + PagerNode, 5 pages built on demand: 3 simple, ListNode, TableNode",
            expected:
                "swipe or tap a tab to change page; indicator follows; feed keeps its position",
            paths: ["status", "tabs", "pager"]
        )
    }
}
