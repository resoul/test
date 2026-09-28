import LayoutCore
import Testing

@testable import Nodes

/// A leaf that writes down what it is told.
@MainActor
private final class Watcher: Node {
    let name: String
    var log: [String] = []

    init(_ name: String, tracks: Bool = false) {
        self.name = name
        super.init()
        tracksScreen = tracks
    }

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 50, height: 20)) }

    override func mountedChanged(_ isMounted: Bool) {
        log.append("mounted \(isMounted)")
    }

    override func shownChanged(_ isShown: Bool) {
        log.append("shown \(isShown)")
    }

    override func screenChanged(_ isOnScreen: Bool) {
        log.append("screen \(isOnScreen)")
    }
}

@MainActor
private final class Pair: Node {
    let first = Watcher("first", tracks: true)
    let second = Watcher("second")
    var showsSecond = true {
        didSet { setNeedsLayout() }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            first
            if showsSecond { second }
        }
        .alignItems(.start)
    }
}

@Test @MainActor
func aHiddenTreeKeepsItsNodesButTheyStopShowing() {
    let pair = Pair()
    let host = NodeHost(root: pair, size: LayoutSize(width: 200, height: 200))
    host.layoutIfNeeded()
    #expect(pair.first.log == ["mounted true", "shown true", "screen true"])
    #expect(pair.isShown)

    host.isShown = false
    #expect(pair.first.isMounted)
    #expect(!pair.first.isShown)
    #expect(!pair.first.isOnScreen)
    host.isShown = true
    #expect(pair.first.isOnScreen)
    #expect(
        pair.first.log == [
            "mounted true", "shown true", "screen true",
            "shown false", "screen false", "shown true", "screen true",
        ]
    )
    host.detach()
}

@Test @MainActor
func aNodeStopsShowingBeforeItLeavesAndJoinsAHiddenTreeUnshown() {
    let pair = Pair()
    let host = NodeHost(root: pair, size: LayoutSize(width: 200, height: 200))
    host.layoutIfNeeded()

    pair.showsSecond = false
    host.layoutIfNeeded()
    #expect(pair.second.log == ["mounted true", "shown true", "shown false", "mounted false"])

    host.isShown = false
    pair.showsSecond = true
    host.layoutIfNeeded()
    #expect(pair.second.isMounted)
    #expect(!pair.second.isShown)
    host.isShown = true
    #expect(pair.second.isShown)
    #expect(
        pair.second.log == [
            "mounted true", "shown true", "shown false", "mounted false",
            "mounted true", "shown true",
        ]
    )
    host.detach()
}
