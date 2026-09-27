#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import LayoutCore
    import Nodes
    import NodesRender
    import Testing

    @testable import NodesAppKit

    @MainActor
    private final class Block: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 200, height: 100)) }
    }

    /// A 100-point title over a 200 × 100 window onto a picture that zooms up to 4.
    @MainActor
    private final class Photo: Node {
        let title = Block()
        lazy var scroll = Scroll(.vertical, content: Block())

        override init() {
            super.init()
            scroll.zoomRange = 1...4
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                title
                scroll
            }
        }
    }

    @MainActor
    private func view(of photo: Photo) -> NodeNSView {
        let view = NodeNSView(root: photo)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        view.layout()
        return view
    }

    @Test @MainActor
    func aPinchZoomsAboutThePointer() {
        let photo = Photo()
        let view = view(of: photo)

        // A pinch doubling the size at the window's top left corner, 100 points down.
        #expect(view.pinch(by: 1, at: LayoutPoint(x: 0, y: 100)))

        #expect(photo.scroll.zoomScale == 2)
        #expect(photo.scroll.contentOffset == LayoutPoint(x: 0, y: 0))
        // Over the title, nothing zooms.
        #expect(!view.pinch(by: 1, at: LayoutPoint(x: 50, y: 50)))
        view.host.detach()
    }

    @Test @MainActor
    func aDoubleTapZoomsInAndBackOut() {
        let photo = Photo()
        let view = view(of: photo)

        #expect(view.smartZoom(at: LayoutPoint(x: 100, y: 150)))
        #expect(photo.scroll.zoomScale == 2)
        // About the window's center: its content point (100, 50) stays there.
        #expect(photo.scroll.contentOffset == LayoutPoint(x: 100, y: 50))

        view.smartZoom(at: LayoutPoint(x: 100, y: 150))
        #expect(photo.scroll.zoomScale == 1)
        view.host.detach()
    }

    @Test @MainActor
    func theWheelMovesZoomedContentBothWays() {
        let photo = Photo()
        let view = view(of: photo)
        photo.scroll.zoom(to: 2, around: .zero)

        view.scroll(by: LayoutPoint(x: 30, y: 20), at: LayoutPoint(x: 100, y: 150))

        #expect(photo.scroll.contentOffset == LayoutPoint(x: 30, y: 20))
        // Across the vertical scroll's axis alone.
        view.scroll(by: LayoutPoint(x: 10, y: 0), at: LayoutPoint(x: 100, y: 150))
        #expect(photo.scroll.contentOffset == LayoutPoint(x: 40, y: 20))
        view.host.detach()
    }
#endif
