#if canImport(UIKit)
    import LayoutCore
    import Nodes
    import Testing
    import UIKit

    @testable import NodesUIKit

    @MainActor
    private final class Block: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 200, height: 100)) }
    }

    @MainActor
    private final class Photo: Node {
        lazy var scroll = Scroll(.vertical, content: Block())

        override init() {
            super.init()
            scroll.zoomRange = 1...3
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    @Test @MainActor
    func aZoomingScrollIsPinchedAndTakesTheScaleCodeSets() throws {
        guard UIDevice.current.userInterfaceIdiom != .tv else { return }

        let photo = Photo()
        let view = NodeView(root: photo)
        view.zoom = 1
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutIfNeeded()
        let driver = try #require(view.scrollDriver(for: photo.scroll))

        // The pinch is the node view's, as the pan is.
        #expect(driver.physicsZoomRange == 1...3)
        #expect(driver.zoomGestures.count == 1)
        #expect(driver.zoomGestures.allSatisfy { $0.view === view })

        photo.scroll.zoom(to: 2)
        view.layoutIfNeeded()

        #expect(driver.physicsZoomScale == 2)
        // The scroll view reaches the whole zoomed content, both ways.
        #expect(driver.contentSize == CGSize(width: 400, height: 200))
        view.host.detach()
    }
#endif
