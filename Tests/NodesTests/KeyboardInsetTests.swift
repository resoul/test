import LayoutCore
import StateCore
import Testing

@testable import Nodes

@MainActor
private final class Block: Node {
    var height: Double {
        didSet { setNeedsLayout() }
    }

    init(height: Double) {
        self.height = height
        super.init()
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 300, height: height)) }
}

/// A scroll with a field at the end of a long text, above the keyboard.
@MainActor
private final class Form: Node {
    let scroll = Scroll(.vertical)
    let field = EmbeddedNode()

    override init() {
        super.init()
        scroll.content = content
    }

    private(set) lazy var content = Content(field: field)

    final class Content: Node {
        let text = Block(height: 600)
        let field: EmbeddedNode

        init(field: EmbeddedNode) {
            self.field = field
            super.init()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                text
                field
            }
        }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            scroll.flex(grow: 1, shrink: 1)
        }
        .padding(bottom: keyboardInset)
    }
}

@Test @MainActor
func theKeyboardShortensWhatReadsItAndAFieldScrollsAboveIt() throws {
    let form = Form()
    let host = NodeHost(root: form, size: LayoutSize(width: 320, height: 700))
    host.layoutIfNeeded()
    #expect(form.scroll.frame.size.height == 700)

    host.keyboardInset = 300
    host.layoutIfNeeded()
    #expect(form.scroll.frame.size.height == 400)
    host.reveal(form.field)
    let shown = try #require(form.scroll.frame(of: form.field))
    #expect(shown.origin.y + shown.size.height - form.scroll.contentOffset.y <= 400)
    host.detach()
}

@Test @MainActor
func anEmbeddedNodeIsFramedWhereItShowsAndCutByTheScroll() throws {
    let form = Form()
    let host = NodeHost(root: form, size: LayoutSize(width: 320, height: 700))
    host.layoutIfNeeded()

    // Below the window: framed where it is, and none of it shows.
    form.content.text.height = 700
    form.content.setNeedsLayout()
    host.layoutIfNeeded()
    let item = try #require(host.embeddedItems().first)
    #expect(item.node === form.field)
    #expect(item.frame.origin.y == 700)
    #expect(item.shownFrame == nil)
    form.scroll.contentOffset = LayoutPoint(x: 0, y: 24)
    let moved = try #require(host.embeddedItems().first)
    #expect(moved.frame.origin.y == 676)
    #expect(moved.shownFrame?.size.height == 24)
    host.detach()
}
