import Foundation
import Testing

@testable import LayoutCore

/// An element with fixed or measured content that records the frame it receives.
@MainActor
private final class Box: LayoutElement {
    let layoutContent: LeafContent?
    private(set) var frame: LayoutRect?
    private(set) var isVisible: Bool?

    init(_ width: Double = 0, _ height: Double = 0) {
        layoutContent = .size(width: width, height: height)
    }

    init(content: LeafContent?) {
        layoutContent = content
    }

    func applyLayoutFrame(_ frame: LayoutRect) {
        self.frame = frame
    }

    func applyLayoutVisibility(_ isVisible: Bool) {
        self.isVisible = isVisible
    }
}

extension LayoutRect {
    fileprivate var minX: Double { origin.x }
    fileprivate var minY: Double { origin.y }
    fileprivate var maxX: Double { origin.x + size.width }
}

/// Words of fixed widths wrapped greedily, one line height — text for tests.
private struct Words: ContentMeasurer {
    let lineHeight: Double
    let words: [Double]

    func minContentWidth() -> Double { words.max() ?? 0 }

    func maxContentWidth() -> Double { words.reduce(0, +) }

    /// Words sit on the baseline, so the first baseline is the bottom of the first line.
    func firstBaseline(forWidth width: Double) -> Double? { words.isEmpty ? nil : lineHeight }

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
    .apply(in: LayoutRect(x: 0, y: 0, width: 320, height: 100))

    #expect(avatar.frame == LayoutRect(x: 16, y: 26, width: 48, height: 48))
    #expect(title.frame == LayoutRect(x: 76, y: 30, width: 146, height: 20))
    #expect(subtitle.frame == LayoutRect(x: 76, y: 54, width: 146, height: 16))
    #expect(follow.frame == LayoutRect(x: 234, y: 34, width: 70, height: 32))
}

@MainActor
@Test
func framesAreInTheCoordinateSpaceOfTheRect() {
    let box = Box(10, 10)

    FlexContainer { box }.apply(in: LayoutRect(x: 100, y: 50, width: 30, height: 30))

    #expect(box.frame == LayoutRect(x: 100, y: 50, width: 10, height: 30))
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
    .apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 10))

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
    .apply(in: LayoutRect(x: 0, y: 0, width: 300, height: 100))

    #expect(outside.frame == LayoutRect(x: 8, y: 8, width: 48, height: 48))
    #expect(inside.frame == LayoutRect(x: 72, y: 8, width: 32, height: 32))
    #expect(after.frame?.minX == 112)
}

@MainActor
@Test
func textWrapsToTheWidthItGets() {
    let text = Box(content: .measured(Words(lineHeight: 10, words: [40, 30, 50, 30, 20])))

    FlexContainer(.column) { text }.apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 200))
    #expect(text.frame == LayoutRect(x: 0, y: 0, width: 100, height: 20))

    let spec = FlexContainer(.column) { text }
    #expect(spec.measure(width: .maxContent) == LayoutSize(width: 170, height: 10))
    #expect(spec.measure(width: .definite(60)) == LayoutSize(width: 60, height: 40))
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
    .apply(in: LayoutRect(x: 0, y: 0, width: 300, height: 10), direction: .rightToLeft)

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
    .apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 10), scale: 2)

    let frames = items.compactMap(\.frame)
    #expect(frames.map(\.minX) == [0, 33.5, 66.5])
    #expect(frames[0].maxX == frames[1].minX)
    #expect(frames[1].maxX == frames[2].minX)
    #expect(frames[2].maxX == 100)
}

@MainActor
@Test
func hiddenTakesNoSpaceAndHidesItsElement() {
    let first = Box(10, 10)
    let second = Box(20, 10)
    let third = Box(30, 10)

    FlexContainer(.row) {
        first
        second.hidden()
        third.hidden(false)
    }
    .apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 10))

    #expect(first.isVisible == nil)
    #expect(second.isVisible == false)
    #expect(second.frame == nil)
    #expect(third.isVisible == true)
    #expect(third.frame?.minX == 10)
}

@MainActor
@Test
func invisibleKeepsItsSpace() {
    let spinner = Box(10, 10)
    let label = Box(20, 10)

    FlexContainer(.row) {
        spinner.invisible()
        label
    }
    .apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 10))

    #expect(spinner.isVisible == false)
    #expect(spinner.frame?.size.width == 10)
    #expect(label.frame?.minX == 10)
}

@MainActor
@Test
func breakpointAtTheRootChoosesByTheWidth() {
    let avatar = Box()
    let text = Box(50, 10)
    func spec() -> LayoutSpec {
        Breakpoint(from: .sm) {
            FlexContainer(.row) {
                avatar.size(48)
                text
            }
        } otherwise: {
            FlexContainer(.column) {
                avatar.size(64)
                text
            }
            .alignItems(.start)
        }
    }

    spec().apply(in: LayoutRect(x: 0, y: 0, width: 500, height: 100))
    #expect(avatar.frame == LayoutRect(x: 0, y: 0, width: 48, height: 48))
    #expect(text.frame?.minX == 48)
    #expect(avatar.isVisible == true)

    spec().apply(in: LayoutRect(x: 0, y: 0, width: 300, height: 100))
    #expect(avatar.frame == LayoutRect(x: 0, y: 0, width: 64, height: 64))
    #expect(text.frame?.minY == 64)
    #expect(avatar.isVisible == true)
}

@MainActor
@Test
func breakpointInsideAContainerUsesTheWidthItsParentGives() {
    let wide = Box(10, 10)
    let narrow = Box(10, 10)
    func spec() -> LayoutSpec {
        FlexContainer(.row) {
            Breakpoint(from: 400) {
                wide
            } otherwise: {
                narrow
            }
        }
        .padding(50)
    }

    spec().apply(in: LayoutRect(x: 0, y: 0, width: 520, height: 110))
    #expect(wide.isVisible == true)
    #expect(narrow.isVisible == false)

    // 480 wide, but the content box that the breakpoint gets is only 380.
    spec().apply(in: LayoutRect(x: 0, y: 0, width: 480, height: 110))
    #expect(wide.isVisible == false)
    #expect(narrow.isVisible == true)
}

@MainActor
@Test
func valuesFromAWidthOnApplyInOrder() {
    let a = Box(10, 10)
    let b = Box(10, 10)
    func spec() -> LayoutSpec {
        FlexContainer(.row) {
            a
            b
        }
        .gap(8)
        .gap(16, from: .md)
        .direction(.column, from: .lg)
    }

    spec().apply(in: LayoutRect(x: 0, y: 0, width: 500, height: 100))
    #expect(b.frame?.minX == 18)

    spec().apply(in: LayoutRect(x: 0, y: 0, width: 700, height: 100))
    #expect(b.frame?.minX == 26)

    spec().apply(in: LayoutRect(x: 0, y: 0, width: 900, height: 100))
    #expect(b.frame?.minX == 0)
    #expect(b.frame?.minY == 26)
}

@MainActor
@Test
func spacingStepsComeFromTheScale() {
    let box = Box(10, 10)
    let spec = FlexContainer(.row) { box }.padding(.s5).gap(.s2)

    spec.apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 100))
    #expect(box.frame?.origin == LayoutPoint(x: 16, y: 16))

    let roomy = SpacingScale(steps: [3, 6, 9, 12, 20, 30, 40, 60, 80])
    spec.apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 100), spacing: roomy)
    #expect(box.frame?.origin == LayoutPoint(x: 20, y: 20))
}
