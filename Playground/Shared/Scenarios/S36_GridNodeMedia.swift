import Foundation
import TrellisCore

/// R12b consumer: a `GridNode` media wall — square tiles in adaptive columns (at least 96 pt),
/// 30 tiles per page from a slow fake API, the next page two viewport lengths before the end.
/// Rotating the device or resizing the window reflows the columns and keeps the tile at the top
/// in place. Same loading hooks and runtime as S35's `ListNode`.
@MainActor enum S36 {
    struct Tile: Sendable, Equatable {
        let hue: Int
    }

    @MainActor
    final class TileProvider: ItemProvider {
        func makeNode(for item: Tile, id: Int) -> TextNode {
            let node = TextNode(
                text: "\(id)",
                textStyle: TextStyle(pointSize: 13, weight: .semibold, alignment: .center)
            )
            node.appearance = VisualStyle(background: .color(Self.color(item.hue)), cornerRadius: 8)
            node.accessibility.label = "Tile \(id)"
            return node
        }

        func update(_ node: TextNode, with item: Tile, id: Int) {
            node.appearance.background = .color(Self.color(item.hue))
        }

        static func color(_ hue: Int) -> ThemeColor {
            let palette = [
                Palette.blue, Palette.purple, Palette.green, Palette.orange, Palette.cyan,
            ]
            return palette[hue % palette.count]
        }
    }

    @MainActor
    final class MediaModel {
        let source = StateSubject(CollectionSnapshot<Int, Tile>.initial(dataKey: "media"))
        weak var loader: CollectionLoader<Int, Tile>?

        func load(_ context: CollectionLoadContext) async -> CollectionLoadResult {
            try? await Task.sleep(for: .milliseconds(600))
            guard let loader, loader.isCurrent(context) else { return .completed }

            let current = source.current
            let page = (current.count..<current.count + (context.pageSize ?? 30)).map {
                CollectionItem(id: $0, value: Tile(hue: $0))
            }
            source.send(
                CollectionSnapshot(
                    dataKey: context.dataKey,
                    revision: current.revision + 1,
                    items: current.items + page
                )
            )
            return .completed
        }
    }

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style { $0.flexDirection = .column }

        let model = MediaModel()
        var style = LayoutStyle()
        style.width = .fraction(1)
        style.flexGrow = 1
        style.flexShrink = 1
        let grid = GridNode(
            source: model.source,
            provider: TileProvider(),
            layout: GridLayout(
                columns: .adaptive(minimumWidth: 96),
                columnSpacing: 6,
                cellHeight: .aspectRatio(1)
            ),
            rowSpacing: 6,
            pagination: PaginationPolicy(pageSize: 30),
            style: style
        )
        // The grid's loader owns the model through its hooks; the model keeps it weakly.
        grid.loader.onLoad = { await model.load($0) }
        grid.loader.onLoadMore = { await model.load($0) }
        model.loader = grid.loader
        root.addSubnode(grid)

        return ScenarioNodes.instance(
            .s36,
            root: root,
            inputs: "GridNode, square tiles in adaptive columns, 30 per page from a slow API",
            expected:
                "columns follow the width; next page before the end; top tile stays on reflow",
            paths: ["grid"]
        )
    }
}
