import Foundation
import Testing

@testable import LayoutCore

/// An element with fixed or measured content that records the frame it receives.
@MainActor
private final class Box: LayoutElement {
    let layoutContent: LeafContent?
    private(set) var frame: CGRect?

    init(_ width: Double = 0, _ height: Double = 0) {
        layoutContent = .size(width: width, height: height)
    }

    init(content: LeafContent?) {
        layoutContent = content
    }

    func applyLayoutFrame(_ frame: CGRect) {
        self.frame = frame
    }
}

/// Words of fixed widths wrapped greedily, one line height — text for tests.
private struct Words: ContentMeasurer {
    let lineHeight: Double
    let words: [Double]

    func minContentWidth() -> Double { words.max() ?? 0 }

    func maxContentWidth() -> Double { words.reduce(0, +) }

    func height(forWidth width: Double) -> Double {
        var lines = words.isEmpty ? 0 : 1
        var used = 0.0
        for word in words {
            if used > 0 && used + word > width + 1e-9 {
                lines += 1
                used = word
            } else {
                used += word
            }
        }
        return Double(lines) * lineHeight
    }
}

@MainActor
@Test
func profileCardMatchesTheBrowserLayout() {
    // The same card as the `nested/profile-card` conformance case, which Chromium lays out
    // with the avatar at (16, 26), the texts at x 76 and the button at x 234.
    let avatar = Box()
    let title = Box(120, 20)
    let subtitle = Box(90, 16)
    let follow = Box(70, 32)

    FlexContainer(.row) {
        avatar.size(48)
        FlexContainer(.column) {
            title
            subtitle
        }
        .gap(4)
        .flex(grow: 1, shrink: 1)
        follow
    }
    .alignItems(.center)
    .gap(12)
    .padding(16)
    .apply(in: CGRect(x: 0, y: 0, width: 320, height: 100))

    #expect(avatar.frame == CGRect(x: 16, y: 26, width: 48, height: 48))
    #expect(title.frame == CGRect(x: 76, y: 30, width: 146, height: 20))
    #expect(subtitle.frame == CGRect(x: 76, y: 54, width: 146, height: 16))
    #expect(follow.frame == CGRect(x: 234, y: 34, width: 70, height: 32))
}

@MainActor
@Test
func framesAreInTheCoordinateSpaceOfTheRect() {
    let box = Box(10, 10)

    FlexContainer { box }.apply(in: CGRect(x: 100, y: 50, width: 30, height: 30))

    #expect(box.frame == CGRect(x: 100, y: 50, width: 10, height: 30))
}

@MainActor
@Test
func conditionsLoopsAndOptionalsBuildTheItemList() {
    let a = Box(10, 10)
    let b = Box(20, 10)
    let missing: Box? = nil
    let rows = [Box(5, 5), Box(5, 5)]
    let showB = false

    FlexContainer(.row) {
        a
        missing
        if showB { b }
        for row in rows { row }
    }
    .apply(in: CGRect(x: 0, y: 0, width: 100, height: 10))

    #expect(a.frame?.minX == 0)
    #expect(b.frame == nil)
    #expect(rows.map { $0.frame?.minX } == [10, 15])
}

@MainActor
@Test
func paddingOnAnElementAppliesToWhatCameBefore() {
    let outside = Box()
    let inside = Box()
    let after = Box(10, 10)

    FlexContainer(.row) {
        outside.size(48).padding(8)
        inside.padding(8).size(48)
        after
    }
    .alignItems(.start)
    .apply(in: CGRect(x: 0, y: 0, width: 300, height: 100))

    #expect(outside.frame == CGRect(x: 8, y: 8, width: 48, height: 48))
    #expect(inside.frame == CGRect(x: 72, y: 8, width: 32, height: 32))
    #expect(after.frame?.minX == 112)
}

@MainActor
@Test
func textWrapsToTheWidthItGets() {
    let text = Box(content: .measured(Words(lineHeight: 10, words: [40, 30, 50, 30, 20])))

    FlexContainer(.column) { text }.apply(in: CGRect(x: 0, y: 0, width: 100, height: 200))
    #expect(text.frame == CGRect(x: 0, y: 0, width: 100, height: 20))

    let spec = FlexContainer(.column) { text }
    #expect(spec.measure(width: .maxContent) == CGSize(width: 170, height: 10))
    #expect(spec.measure(width: .definite(60)) == CGSize(width: 60, height: 40))
}

@MainActor
@Test
func rightToLeftStartsRowsAtTheRight() {
    let first = Box(40, 10)
    let second = Box(60, 10)

    FlexContainer(.row) {
        first
        second
    }
    .apply(in: CGRect(x: 0, y: 0, width: 300, height: 10), direction: .rightToLeft)

    #expect(first.frame?.minX == 260)
    #expect(second.frame?.minX == 200)
}

@MainActor
@Test
func framesSnapToThePixelGridWithoutGaps() {
    let items = [Box(), Box(), Box()]

    FlexContainer(.row) {
        for item in items { item.flex(grow: 1) }
    }
    .apply(in: CGRect(x: 0, y: 0, width: 100, height: 10), scale: 2)

    let frames = items.compactMap(\.frame)
    #expect(frames.map(\.minX) == [0, 33.5, 66.5])
    #expect(frames[0].maxX == frames[1].minX)
    #expect(frames[1].maxX == frames[2].minX)
    #expect(frames[2].maxX == 100)
}
