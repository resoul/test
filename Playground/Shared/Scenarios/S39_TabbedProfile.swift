import Foundation
import TrellisCore

/// R14 consumer (ADR 0037, the Telegram model): a full-bleed profile header over a pinned
/// segmented bar and three pages — a long `GridNode` media wall, a long `TableNode` of files
/// (its swipe actions disabled by the pager, still reachable through accessibility) and a short
/// `ListNode` of links. Scrolling a page first collapses the header; the tabs pin under the
/// status bar and only then the page scrolls. The status line (accessibility identifier
/// `r14-status`) reports selection, pin state, collapse progress and mounted pages.
@MainActor enum S39 {
    @MainActor
    final class Model {
        let media = StateSubject(
            CollectionSnapshot(
                dataKey: "media",
                revision: 1,
                items: (0..<90).map { CollectionItem(id: $0, value: S36.Tile(hue: $0)) }
            )
        )
        let files = StateSubject(
            CollectionSnapshot(
                dataKey: "files",
                revision: 1,
                items: (0..<60).map {
                    CollectionItem(id: $0, value: S38.Row(title: "Document \($0).pdf"))
                }
            )
        )
        let links = StateSubject(
            CollectionSnapshot(
                dataKey: "links",
                revision: 1,
                items: (0..<3).map {
                    CollectionItem(id: $0, value: S38.Row(title: "https://example.org/\($0)"))
                }
            )
        )
        var lastAction = "none"
    }

    static func header(status: TextNode) -> Node {
        let header = Node(appearance: VisualStyle(background: .color(Palette.card)))
        header.style {
            $0.flexDirection = .column
            $0.alignItems = .center
            $0.gap = 10
            $0.padding = DirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        }
        // The header runs under the status bar; its content starts below it.
        header.safeAreaBoundary = true
        header.safeAreaIgnoredEdges = [.leading, .bottom, .trailing]

        let avatar = Node(
            appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 40)
        )
        avatar.style {
            $0.width = .points(80)
            $0.height = .points(80)
        }
        let name = TextNode(
            text: "Ada Trellis",
            textStyle: TextStyle(pointSize: 22, weight: .semibold, color: Palette.theme.colors.text)
        )
        let about = TextNode(
            text: "Profile header of any height: avatar, name and information blocks.",
            textStyle: TextStyle(pointSize: 14, alignment: .center, color: Palette.textSecondary)
        )
        header.addSubnode(status)
        header.addSubnode(avatar)
        header.addSubnode(name)
        header.addSubnode(about)
        header.addSubnode(infoBlock(title: "Username", value: "@ada"))
        header.addSubnode(infoBlock(title: "Bio", value: "Lays out trees on the main actor."))
        return header
    }

    static func infoBlock(title: String, value: String) -> Node {
        let block = Node(
            appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 10)
        )
        block.style {
            $0.flexDirection = .column
            $0.alignSelf = .stretch
            $0.gap = 2
            $0.padding = DirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        }
        let valueStyle = TextStyle(pointSize: 15, color: Palette.theme.colors.text)
        let titleStyle = TextStyle(pointSize: 12, color: Palette.textSecondary)
        block.addSubnode(TextNode(text: value, textStyle: valueStyle))
        block.addSubnode(TextNode(text: title, textStyle: titleStyle))
        return block
    }

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style { $0.padding = DirectionalEdgeInsets() }
        // Full bleed at the top: the header, not the root, keeps its content below the status
        // bar, and the tabs pin under it (ADR 0037 §1).
        root.safeAreaIgnoredEdges = [.top]

        let status = TextNode(text: "selected=media", textStyle: TextStyle(pointSize: 12))
        status.accessibility.identifier = "r14-status"
        status.accessibility.label = "Profile status"

        let model = Model()
        var style = LayoutStyle()
        style.width = .fraction(1)
        style.flexGrow = 1
        style.flexShrink = 1
        let tabbed = TabbedScrollNode(
            header: header(status: status),
            tabs: .segmented(placement: .pinned),
            pages: [
                Tab(id: "media", title: "Media") {
                    GridNode(
                        source: model.media,
                        provider: S36.TileProvider(),
                        layout: GridLayout(
                            columns: .adaptive(minimumWidth: 96),
                            columnSpacing: 4,
                            cellHeight: .aspectRatio(1)
                        ),
                        rowSpacing: 4
                    )
                },
                Tab(id: "files", title: "Files") {
                    let table = TableNode(source: model.files, provider: S38.RowProvider())
                    table.trailingActions = { _ in
                        [
                            RowAction(id: "delete", title: "Delete") { id in
                                model.lastAction = "deleted \(id)"
                                return .completed
                            }
                        ]
                    }
                    return table
                },
                Tab(id: "links", title: "Links") {
                    ListNode(source: model.links, provider: S38.RowProvider())
                },
            ],
            style: style
        )
        root.addSubnode(tabbed)

        let report: @MainActor () -> Void = { [weak status, weak tabbed] in
            guard let status, let tabbed else { return }

            let text =
                "selected=\(tabbed.selection ?? "-") pinned=\(tabbed.isPinned) "
                + "collapse=\(String(format: "%.2f", tabbed.collapseProgress)) "
                + "mounted=\(tabbed.pager.mountedIDs.joined(separator: ",")) "
                + "action=\(model.lastAction)"
            status.text = text
            status.accessibility.value = text
        }
        tabbed.onCollapseProgressChange = { _ in report() }
        tabbed.pager.onProgressChange = { _, _ in report() }
        report()

        return ScenarioNodes.instance(
            .s39,
            root: root,
            inputs: "TabbedScrollNode: profile header, pinned tabs, grid/table/short list pages",
            expected:
                "a page drag first collapses the header; tabs pin under the status bar; pages "
                + "keep their positions; a deep page selected with the header open pins the tabs",
            paths: ["header", "tabs", "pager"]
        )
    }
}
