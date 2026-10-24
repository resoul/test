#if canImport(CoreText)
    import Foundation
    import LayoutCore
    import Nodes
    import Testing
    @testable import NodesRender

    private struct PlannedRow: Identifiable, Sendable {
        let id: Int
        var revision = 0
    }

    @MainActor private final class PlanCell: Node {
        var length = 44.0
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: length)) }
    }

    @Test @MainActor func tableEditingPreparationUsesTheInnerContentWidth() async {
        let cells = NodeCache<Int, PlanCell> { _ in PlanCell() }
        let table = Table<PlannedRow>(
            preparation: ItemPreparationPolicy(),
            key: { $0.revision },
            prepare: { _, context in PreparedItem(context.crossAxisLength, length: 44) },
            row: { item, state in
                let cell = cells[item.id]
                if case let .ready(plan) = state { cell.accessibility.label = String(plan.value) }
                return cell
            }
        )
        table.sections = [TableSection(id: "rows", items: (0..<5).map { PlannedRow(id: $0) })]
        let host = NodeHost(root: table, size: LayoutSize(width: 320, height: 200))
        defer { host.detach() }
        host.layoutIfNeeded()
        await table.preparationsFinished()
        host.layoutIfNeeded()
        #expect(cells[0].accessibility.label == "320.0")
        table.onMove = { _ in }
        table.allowsMultipleSelectionDuringEditing = true
        table.isEditing = true
        host.layoutIfNeeded()
        await table.preparationsFinished()
        host.layoutIfNeeded()
        #expect(cells[0].accessibility.label == "234.0")
        #expect(!host.needsLayout)
    }
#endif

#if canImport(CoreText)
    @MainActor
    private final class WideTableContent: Node {
        let photo = WideIntrinsicImage()
        let text = Text(
            String(repeating: "A paragraph that must wrap within the table. ", count: 5)
        )
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                text
                photo.width(.fraction(1)).aspectRatio(1.6).limits(minWidth: .points(0))
            }.width(.fraction(1)).limits(minWidth: .points(0))
        }
    }

    @MainActor
    private final class WideIntrinsicImage: Node {
        override var layoutContent: LeafContent? {
            .proportional(LayoutSize(width: 1280, height: 800))
        }
    }

    @Test @MainActor
    func aTableCellShrinksWideIntrinsicContentToTheRowWidth() throws {
        let card = WideTableContent()
        let table = Table<PlannedRow> { _ in card }
        table.sections = [TableSection(id: "rows", items: [PlannedRow(id: 0)])]
        let host = NodeHost(root: table, size: LayoutSize(width: 320, height: 600))
        defer { host.detach() }
        host.layoutIfNeeded()
        let cell = try #require(card.supernode)
        #expect(cell.frame.size.width == 320)
        #expect(card.frame.size.width == 320)
        #expect(card.photo.frame.size.width == 320)
        #expect(card.text.frame.size.width == 320)
        #expect(card.text.frame.size.height > 40)
    }
#endif
