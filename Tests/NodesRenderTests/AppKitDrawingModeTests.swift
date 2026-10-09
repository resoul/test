#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    @testable import NodesAppKit

    @MainActor
    private final class Label: Node {
        let text = Text("Hello")

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { text }.alignItems(.start)
        }
    }

    @MainActor
    private func view(of label: Label) -> NodeNSView {
        let view = NodeNSView(root: label)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layout()
        return view
    }

    @Test @MainActor
    func aViewDrawsOnTheMainThreadByDefault() {
        let label = Label()
        let view = view(of: label)

        #expect(view.renderedLayer(for: label.text)?.contents != nil)
        view.host.detach()
    }

    @Test @MainActor
    func aViewWhoseHostDrawsInTheBackgroundShowsTheBitmapLater() async {
        let background = Label()
        let view = NodeNSView(root: background)
        view.host.drawingMode = .asynchronous
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layout()

        #expect(view.renderedLayer(for: background.text)?.contents == nil)
        for _ in 0..<500 where view.renderedLayer(for: background.text)?.contents == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(view.renderedLayer(for: background.text)?.contents != nil)
        view.host.detach()
    }

    @Test @MainActor
    func changingTheHostsModeAsksForARender() {
        let label = Label()
        let host = NodeHost(root: label, size: LayoutSize(width: 200, height: 100))
        host.layoutIfNeeded()
        host.didRender()

        host.drawingMode = .asynchronous
        #expect(host.needsRender)
        host.didRender()
        host.displayRange = DisplayRange()
        #expect(host.needsRender)
        host.detach()
    }
#endif
