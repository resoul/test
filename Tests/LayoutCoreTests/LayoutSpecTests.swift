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
func ifAppliesItsModifiersOnlyWhileTheConditionHolds() {
    let title = Box(20, 10)
    let next = Box(10, 10)
    func spec(_ isHighlighted: Bool) -> LayoutSpec {
        FlexContainer(.row) {
            title.if(isHighlighted) { $0.margin(8) }
            next
        }
    }

    spec(true).apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 40))
    #expect(title.frame?.minX == 8)
    #expect(next.frame?.minX == 36)

    spec(false).apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 40))
    #expect(title.frame?.minX == 0)
    #expect(next.frame?.minX == 20)
}

@MainActor
@Test
func anEmptyContainerCollapsesOnlyWhenAsked() {
    let after = Box(10, 10)
    func spec(badge: Box?, collapses: Bool) -> LayoutSpec {
        let badges = FlexContainer(.row) { badge }.padding(6)
        return FlexContainer(.row) {
            collapses ? badges.collapsesWhenEmpty() : badges
            after
        }
    }

    // CSS keeps the padding of an empty container.
    spec(badge: nil, collapses: false).apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 20))
    #expect(after.frame?.minX == 12)

    spec(badge: nil, collapses: true).apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 20))
    #expect(after.frame?.minX == 0)

    // An item that is present keeps the container, even while it is hidden.
    let badge = Box(10, 10)
    spec(badge: badge, collapses: true).apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 20))
    #expect(badge.frame?.minX == 6)
    #expect(after.frame?.minX == 22)

    FlexContainer(.row) {
        FlexContainer(.row) { badge.hidden() }.padding(6).collapsesWhenEmpty()
        after
    }
    .apply(in: LayoutRect(x: 0, y: 0, width: 100, height: 20))
    #expect(after.frame?.minX == 12)
}

@MainActor
@Test
func anElementLaidOutInTwoPlacesIsReported() throws {
    let badge = Box(10, 10)
    let other = Box(10, 10)
    let rect = LayoutRect(x: 0, y: 0, width: 100, height: 20)
    func check(_ spec: LayoutSpec) throws -> [ObjectIdentifier] {
        let prepared = spec.prepare()
        let result = try FlexboxEngine.layout(prepared.input, size: rect.size)
        return prepared.elementsPlacedMoreThanOnce(in: result).map { ObjectIdentifier($0) }
    }

    #expect(
        try check(
            FlexContainer(.row) {
                badge; other; badge; badge
            }
        ) == [ObjectIdentifier(badge)]
    )
    // Both branches mention it; only one is laid out.
    #expect(
        try check(
            Breakpoint(from: 50) {
                badge
            } otherwise: {
                badge
            }
        ).isEmpty
    )
    // A hidden place has no frame.
    #expect(
        try check(
            FlexContainer(.row) {
                badge; badge.hidden()
            }
        ).isEmpty
    )
}

@MainActor
@Test
func idsLeadBackToTheirElements() {
    let first = Box(10, 10)
    let second = Box(10, 10)
    let prepared = FlexContainer(.row) {
        first
        second
        first
    }
    .prepare()

    let ids = prepared.ids(of: first)
    #expect(ids.count == 2)
    #expect(ids.allSatisfy { prepared.element(for: $0) === first })
    #expect(prepared.element(for: prepared.input.id) == nil)
}

@MainActor
@Test
func nilArgumentsLeaveTheSpecAsItWas() {
    let a = Box(10, 10)
    let b = Box(10, 10)
    let rect = LayoutRect(x: 0, y: 0, width: 100, height: 40)
    let noPoints: Double? = nil
    let noStep: Spacing? = nil
    let isCompact = true
    func frames(_ spec: LayoutSpec) -> [LayoutRect?] {
        spec.apply(in: rect)
        return [a.frame, b.frame]
    }

    let plain = frames(
        FlexContainer(.row) {
            a; b
        }
    )
    let withNils = frames(
        FlexContainer(.row) {
            a.padding(noPoints).margin(noStep).size(nil).alignSelf(nil).order(nil)
                .aspectRatio(nil).width(nil).height(nil)
            b.padding(isCompact ? nil : 16).margin(isCompact ? nil : .s4)
        }
        .gap(noPoints).gap(isCompact ? nil : .s2).direction(nil).justifyContent(nil)
        .alignItems(nil).alignContent(nil).wrap(nil).padding(noStep)
    )
    #expect(withNils == plain)

    // The same forms with values apply them: a 10 wide, a gap of 6, then 4 of padding.
    let spaced = frames(
        FlexContainer(.row) {
            a; b.padding(isCompact ? 4 : nil)
        }.gap(isCompact ? 6 : nil)
    )
    #expect(spaced[1]?.minX == 20)
}

@MainActor
@Test
func paddingWithEverySideNilChangesNothing() {
    let plain = Box(10, 10)
    let padded = Box(10, 10)
    let rect = LayoutRect(x: 0, y: 0, width: 100, height: 40)

    FlexContainer(.row) { plain.alignSelf(.center) }.apply(in: rect)
    let none: Double? = nil
    FlexContainer(.row) { padded.alignSelf(.center).padding(top: none) }.apply(in: rect)

    #expect(padded.frame == plain.frame)
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

/// An element that lays out its own subelements in the same pass.
@MainActor
private final class Panel: LayoutElement {
    let layoutContent: LeafContent? = nil
    var layout: () -> LayoutSpec?
    private(set) var frame: LayoutRect?

    init(_ layout: @escaping () -> LayoutSpec?) {
        self.layout = layout
    }

    var embeddedLayout: LayoutSpec? { layout() }

    func applyLayoutFrame(_ frame: LayoutRect) {
        self.frame = frame
    }
}

@Test @MainActor
func anEmbeddedLayoutPlacesItsElementsRelativeToTheirContainer() {
    let icon = Box(20, 20)
    let label = Box(50, 10)
    let panel = Panel {
        FlexContainer(.row) {
            icon; label
        }.gap(5).padding(10)
    }
    let placements = FlexContainer(.column) { panel }
        .padding(30)
        .apply(in: LayoutRect(x: 0, y: 0, width: 200, height: 200))

    #expect(panel.frame == LayoutRect(x: 30, y: 30, width: 140, height: 40))
    #expect(icon.frame == LayoutRect(x: 10, y: 10, width: 20, height: 20))
    #expect(label.frame == LayoutRect(x: 35, y: 10, width: 50, height: 20))
    #expect(placements.map { $0.container === panel } == [false, true, true])
}

@Test @MainActor
func placeModifiersApplyOnTopOfTheEmbeddedStyle() {
    let icon = Box(20, 20)
    let panel = Panel { FlexContainer { icon }.padding(10).width(40) }
    FlexContainer(.row) { panel.width(100) }
        .apply(in: LayoutRect(x: 0, y: 0, width: 300, height: 50))

    #expect(panel.frame?.size.width == 100)
    #expect(icon.frame?.origin == LayoutPoint(x: 10, y: 10))
}

@Test @MainActor
func anElementEmbeddingItselfIsPlacedAsALeafThere() throws {
    let panel = Panel { nil }
    panel.layout = { FlexContainer { panel } }
    let rect = LayoutRect(x: 0, y: 0, width: 100, height: 100)
    let prepared = FlexContainer { panel }.prepare()
    let result = try FlexboxEngine.layout(prepared.input, size: rect.size)

    #expect(prepared.apply(result, in: rect).count == 2)
    // It has a frame in both places, so applying the spec rejects the pass.
    #expect(FlexContainer { panel }.apply(in: rect).isEmpty)
}

@MainActor
@Test
func applyReportsWhatThePassFound() {
    let badge = Box(10, 10)
    let other = Box(20, 10)
    let rect = LayoutRect(x: 0, y: 0, width: 100, height: 20)
    var reports: [LayoutSpecReport] = []
    func reporting(
        traceAreas: Set<LayoutTraceArea> = [],
        traced: [any LayoutElement]? = nil
    ) -> LayoutSpecReporting {
        LayoutSpecReporting(host: "Card", traceAreas: traceAreas, tracedElements: traced) {
            reports.append($0)
        }
    }

    // A clean pass: applied, nothing to fix.
    FlexContainer(.row) {
        badge; other
    }.alignItems(.start).apply(in: rect, reporting: reporting())
    #expect(reports.count == 1)
    #expect(reports[0].hasProblems == false)
    #expect(reports[0].elements == 2)
    #expect(
        reports[0].lines[0].hasSuffix(
            "rejected=no stack=enough duplicates=none widthless=none"
        )
    )
    #expect(badge.frame == LayoutRect(x: 0, y: 0, width: 10, height: 10))

    // An element in two places: the pass is rejected, every element keeps its frame.
    let placements = FlexContainer(.row) {
        other; badge; other
    }
    .alignItems(.start).apply(in: rect, reporting: reporting())
    #expect(placements.isEmpty)
    #expect(badge.frame == LayoutRect(x: 0, y: 0, width: 10, height: 10))
    #expect(reports[1].isRejected)
    #expect(reports[1].duplicates.map { ObjectIdentifier($0) } == [ObjectIdentifier(other)])
    #expect(reports[1].lines[0].contains("rejected=yes stack=enough duplicates=#0:Box "))
    #expect(reports[1].generation == reports[0].generation + 1)

    // A trace of one element.
    FlexContainer(.row) {
        badge; other
    }
    .alignItems(.start)
    .apply(in: rect, reporting: reporting(traceAreas: [.place], traced: [other]))
    #expect(reports[2].trace.count == 1)
    #expect(reports[2].lines.count == 2)
    #expect(
        reports[2].lines[1]
            == "[layout] place host=Card gen=\(reports[2].generation) #1:Box x=10 y=0 size=20x10"
    )
}

@MainActor
@Test
func applyReportsVariantsChosenWithoutAWidth() {
    let wide = Box(10, 10)
    let narrow = Box(20, 10)
    var report: LayoutSpecReport?
    // The inner row sizes itself to its content, so its breakpoint has no width to go by.
    FlexContainer(.row) {
        FlexContainer(.row) {
            Breakpoint(from: 50) {
                wide
            } otherwise: {
                narrow
            }
        }
    }
    .alignItems(.start)
    .apply(
        in: LayoutRect(x: 0, y: 0, width: 100, height: 20),
        reporting: LayoutSpecReporting(host: "Card") { report = $0 }
    )
    #expect(report?.hasProblems == true)
    #expect(report?.lines[0].hasSuffix("widthless=none") == false)
}
