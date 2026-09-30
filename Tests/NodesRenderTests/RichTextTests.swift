#if canImport(CoreText)
    import CoreText
    import Foundation
    import LayoutCore
    import Nodes
    import QuartzCore
    import RichTextCore
    import Testing

    @testable import NodesRender

    @MainActor
    private final class Column: Node {
        let text: Text
        init(_ text: Text) { self.text = text }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { text }.alignItems(.start)
        }
    }

    private let sample = "The quick brown fox jumps over the lazy dog and keeps running"
    private let site = URL(string: "https://example.com/page")!

    @MainActor
    private func laidOut(_ text: Text, width: Double) -> (Column, NodeHost) {
        let column = Column(text)
        let host = NodeHost(root: column, size: LayoutSize(width: width, height: 800))
        host.layoutIfNeeded()
        return (column, host)
    }

    private func font(at index: Int, of layout: RichBlockLayout) -> CTFont {
        CFAttributedStringGetAttribute(layout.string, index, kCTFontAttributeName, nil) as! CTFont
    }

    private let metrics = RichMetrics(TextStyle())

    private func layout(_ block: RichText.Block, width: Double = 300) -> RichBlockLayout {
        RichBlockLayout(block, width: width, metrics: metrics, colors: .measuring)
    }

    // MARK: Fonts

    @Test func marksSelectTheFontFaceTheyAskFor() {
        let block = RichText.Block.paragraph([
            Run("plain "), Run("bold ", marks: .bold), Run("italic ", marks: .italic),
            Run("code", marks: .mono),
        ])
        let made = layout(block)
        func traits(_ index: Int) -> CTFontSymbolicTraits {
            CTFontGetSymbolicTraits(font(at: index, of: made))
        }
        #expect(!traits(0).contains(.traitBold))
        #expect(traits(6).contains(.traitBold))
        #expect(traits(11).contains(.traitItalic))
        #expect(traits(18).contains(.traitMonoSpace))
        #expect(!traits(0).contains(.traitMonoSpace))
    }

    @Test func boldAndItalicTogetherGiveBoth() {
        let made = layout(.paragraph([Run("both", marks: [.bold, .italic])]))
        let traits = CTFontGetSymbolicTraits(font(at: 0, of: made))
        #expect(traits.contains(.traitBold) && traits.contains(.traitItalic))
    }

    // MARK: Size

    @Test @MainActor func aPlainParagraphIsAsHighAsPlainTextOfTheSameWords() {
        let (plain, plainHost) = laidOut(Text(sample), width: 180)
        let (rich, richHost) = laidOut(Text(rich: RichText(plain: sample)), width: 180)
        #expect(rich.text.frame.size.height == plain.text.frame.size.height)
        #expect(rich.text.frame.size.width == plain.text.frame.size.width)
        plainHost.detach()
        richHost.detach()
    }

    @Test @MainActor func blocksAreSetOneUnderAnotherWithSpaceBetween() {
        let one = RichText(blocks: [.paragraph([Run(sample)])])
        let three = RichText(
            blocks: [
                .paragraph([Run(sample)]), .paragraph([Run(sample)]), .paragraph([Run(sample)]),
            ]
        )
        let (a, hostA) = laidOut(Text(rich: one), width: 180)
        let (b, hostB) = laidOut(Text(rich: three), width: 180)
        let each = a.text.frame.size.height
        let spacing = metrics.blockSpacing
        #expect(abs(b.text.frame.size.height - (3 * each + 2 * spacing)) <= 1)
        hostA.detach()
        hostB.detach()
    }

    @Test @MainActor func anEmptyParagraphTakesALineAndAnEmptyTextTakesOne() {
        let (text, host) = laidOut(Text(rich: RichText()), width: 180)
        #expect(text.text.frame.size.height > 5)
        host.detach()
    }

    @Test func measuringAndDrawingAgreeAtEveryWidth() {
        let text = RichText(
            blocks: [
                .paragraph([Run(sample, marks: .bold), Run(" "), Run(sample, link: site)]),
                .quote([Run(sample, marks: .italic)]),
                .code(String(repeating: "let value = compute(x)\n", count: 2), language: nil),
            ]
        )
        let measurements = RichTextMeasurements()
        let measurer = RichTextMeasurer(
            text: text,
            metrics: metrics,
            maxLines: nil,
            measurements: measurements
        )
        for width in stride(from: 60.0, through: 500.0, by: 37.0) {
            let placed = RichPlacedLayout(
                blocks: text.blocks.map {
                    RichBlockLayout($0, width: width, metrics: metrics, colors: .measuring)
                },
                width: width,
                metrics: metrics,
                maxLines: nil
            )
            #expect(measurer.height(forWidth: width) == ceil(placed.stack.height), "width \(width)")
            for (index, block) in placed.blocks.enumerated() {
                // Every line lies inside the box it is given, and none is dropped.
                var covered = 0
                for line in block.lines {
                    // Spaces at the end of a line hang past the edge; they are not ink.
                    let lineWidth =
                        Double(CTLineGetTypographicBounds(line.line, nil, nil, nil))
                        - CTLineGetTrailingWhitespaceWidth(line.line)
                    #expect(lineWidth <= block.textWidth + 0.5, "clipped at width \(width)")
                    covered += line.range.length
                }
                #expect(covered == CFAttributedStringGetLength(block.string))
                let bottom = block.geometry.lineBottoms.last ?? 0
                #expect(
                    block.geometry.height(showing: nil)
                        >= bottom + block.geometry.insets.top + block.geometry.insets.bottom,
                    "block \(index)"
                )
            }
        }
    }

    @Test func aLongLineOfCodeWrapsAtAnyCharacterAndKeepsAllOfIt() {
        let code = String(repeating: "0123456789", count: 12)
        let made = layout(.code(code, language: nil), width: 160)
        #expect(made.lines.count > 1)
        #expect(made.lines.reduce(0) { $0 + $1.range.length } == code.utf16.count)
        for line in made.lines {
            #expect(
                Double(CTLineGetTypographicBounds(line.line, nil, nil, nil)) <= made.textWidth + 0.5
            )
        }
    }

    @Test func codeBreaksInsideAWordWhereAParagraphBreaksBetweenWords() {
        let text = String(repeating: "abcdefghij ", count: 10)
        func breaksInsideAWord(_ block: RichText.Block) -> Bool {
            let made = layout(block, width: 160)
            let units = Array(text.utf16)
            return made.lines.dropLast().contains { line in
                let end = line.range.location + line.range.length
                return units[end - 1] != 32 && units[end] != 32
            }
        }
        #expect(breaksInsideAWord(.code(text, language: nil)))
        #expect(!breaksInsideAWord(.paragraph([Run(text)])))
    }

    @Test func quoteAndCodeHaveInsetsAndParagraphsHaveNone() {
        #expect(layout(.paragraph([Run("a")])).geometry.insets == BlockGeometry.Insets())
        #expect(layout(.quote([Run("a")])).geometry.insets.left > 0)
        let code = layout(.code("a", language: nil)).geometry.insets
        #expect(code.left > 0 && code.top > 0 && code.right > 0 && code.bottom > 0)
    }

    @Test func aBlocksTextIsNarrowerByItsInsets() {
        let plain = layout(.paragraph([Run(sample)]), width: 200)
        let quote = layout(.quote([Run(sample)]), width: 200)
        #expect(quote.textWidth < plain.textWidth)
        #expect(quote.lines.count >= plain.lines.count)
    }

    @Test @MainActor func maxLinesCountsLinesOverAllBlocks() {
        var style = TextStyle()
        style.maxLines = 3
        let text = RichText(
            blocks: [
                .paragraph([Run(sample)]), .paragraph([Run(sample)]), .paragraph([Run(sample)]),
            ]
        )
        let (limited, hostA) = laidOut(Text(rich: text, style: style), width: 120)
        let (all, hostB) = laidOut(Text(rich: text), width: 120)
        #expect(limited.text.frame.size.height < all.text.frame.size.height)
        let lineHeight = layout(.paragraph([Run("x")]), width: 120).geometry.lineBottoms[0]
        #expect(
            limited.text.frame.size.height <= 3 * ceil(lineHeight) + 2 * metrics.blockSpacing + 2
        )
        hostA.detach()
        hostB.detach()
    }

    // MARK: Links

    @MainActor private func linkText(onLink: @escaping @MainActor (URL) -> Void) -> Text {
        let text = Text(
            rich: RichText(
                blocks: [
                    .paragraph([
                        Run("Read "), Run("the page", link: site), Run(" for more text here"),
                    ])
                ]
            )
        )
        text.onLink = onLink
        return text
    }

    /// The middle of the first link, in the text's coordinates.
    @MainActor private func linkPoint(_ text: Text, width: Double) -> LayoutPoint {
        let placed = RichPlacedLayout(
            blocks: text.rich!.blocks.map {
                RichBlockLayout($0, width: width, metrics: metrics, colors: .measuring)
            },
            width: width,
            metrics: metrics,
            maxLines: nil
        )
        let rect = placed.linkRects[0]
        return LayoutPoint(x: Double(rect.midX), y: Double(rect.midY))
    }

    @Test @MainActor func thePointerIsAHandOverALinkAndAnArrowOnOtherTextAndOnceItLeaves() {
        let text = linkText { _ in }
        let (column, host) = laidOut(text, width: 300)
        column.onTap = {}

        let onLink = linkPoint(text, width: text.frame.size.width)
        host.pointerMoved(
            to: LayoutPoint(x: text.frame.origin.x + onLink.x, y: text.frame.origin.y + onLink.y)
        )
        #expect(host.pointerStyle == .pointingHand)

        // The word "Read" is not a link: the pointer is over the node around the text.
        host.pointerMoved(to: LayoutPoint(x: text.frame.origin.x + 2, y: text.frame.origin.y + 5))
        #expect(host.pointerStyle == .arrow)

        host.pointerMoved(
            to: LayoutPoint(x: text.frame.origin.x + onLink.x, y: text.frame.origin.y + onLink.y)
        )
        host.pointerMoved(to: nil)
        #expect(host.pointerStyle == .arrow)
        host.detach()
    }

    @Test @MainActor func aTextThatHasATapOfItsOwnKeepsTheArrowOverItsLinks() {
        let text = linkText { _ in }
        text.onTap = {}
        let (_, host) = laidOut(text, width: 300)
        let onLink = linkPoint(text, width: text.frame.size.width)
        host.pointerMoved(
            to: LayoutPoint(x: text.frame.origin.x + onLink.x, y: text.frame.origin.y + onLink.y)
        )
        #expect(host.pointerStyle == .arrow, "a tap on the text is not the opening of a link")
        host.detach()
    }

    @Test @MainActor func aTapOnALinkOpensItAndOnOtherTextGoesToWhatIsBehind() {
        var opened: [URL] = []
        let text = linkText { opened.append($0) }
        let (column, host) = laidOut(text, width: 300)
        var behind = 0
        column.onTap = { behind += 1 }

        let onLink = linkPoint(text, width: text.frame.size.width)
        let inRoot = LayoutPoint(
            x: text.frame.origin.x + onLink.x,
            y: text.frame.origin.y + onLink.y
        )
        #expect(host.pointerDown(at: inRoot))
        host.pointerUp(at: inRoot)
        #expect(opened == [site])
        #expect(behind == 0)

        // The word "Read" is not a link: the tap goes to the node around the text.
        let elsewhere = LayoutPoint(x: text.frame.origin.x + 2, y: text.frame.origin.y + 5)
        host.pointerDown(at: elsewhere)
        host.pointerUp(at: elsewhere)
        #expect(opened == [site])
        #expect(behind == 1)
        host.detach()
    }

    @Test @MainActor func textWithoutAHandlerTakesNoPress() {
        let text = linkText { _ in }
        text.onLink = nil
        let (column, host) = laidOut(text, width: 300)
        var behind = 0
        column.onTap = { behind += 1 }
        let point = linkPoint(text, width: text.frame.size.width)
        let inRoot = LayoutPoint(x: text.frame.origin.x + point.x, y: text.frame.origin.y + point.y)
        host.pointerDown(at: inRoot)
        host.pointerUp(at: inRoot)
        #expect(behind == 1)
        host.detach()
    }

    @Test @MainActor func aLinkThatWrapsCanBeTappedOnEachLine() {
        var opened = 0
        let words = String(repeating: "wrapping link words ", count: 6)
        let text = Text(rich: RichText(blocks: [.paragraph([Run(words, link: site)])]))
        text.onLink = { _ in opened += 1 }
        let (_, host) = laidOut(text, width: 140)
        let rects = RichPlacedLayout(
            blocks: [
                RichBlockLayout(
                    text.rich!.blocks[0],
                    width: text.frame.size.width,
                    metrics: metrics,
                    colors: .measuring
                )
            ],
            width: text.frame.size.width,
            metrics: metrics,
            maxLines: nil
        ).linkRects
        #expect(rects.count > 1)
        for rect in rects {
            let point = LayoutPoint(
                x: text.frame.origin.x + Double(rect.midX),
                y: text.frame.origin.y + Double(rect.midY)
            )
            host.pointerDown(at: point)
            host.pointerUp(at: point)
        }
        #expect(opened == rects.count)
        host.detach()
    }

    @Test @MainActor func linksAreActionsOfOneElementAndTheTextIsReadOnce() {
        var opened: [URL] = []
        let other = URL(string: "https://other.example")!
        let text = Text(
            rich: RichText(
                blocks: [
                    .paragraph([Run("See "), Run("one", link: site), Run(" and ")]),
                    .paragraph([Run("two", marks: .bold, link: other)]),
                ]
            )
        )
        text.onLink = { opened.append($0) }
        let (_, host) = laidOut(text, width: 300)

        let entries = host.accessibilityEntries()
        let items = entries.compactMap { entry -> AccessibilityItem? in
            if case .element(let item) = entry { item } else { nil }
        }
        #expect(items.count == 1)
        #expect(items[0].label == "See one and \ntwo")
        #expect(items[0].actions == ["Open link one", "Open link two"])
        #expect(host.performAccessibilityAction(1, of: items[0].node))
        #expect(opened == [other])
        host.detach()
    }

    @Test @MainActor func neighbouringRunsOfOneLinkAreOneAction() {
        let text = Text(
            rich: RichText(
                blocks: [.paragraph([Run("a ", link: site), Run("b", marks: .bold, link: site)])]
            )
        )
        text.onLink = { _ in }
        #expect(text.links.map(\.text) == ["a b"])
        #expect(text.accessibilityActions.map(\.name) == ["Open link a b"])
    }

    @Test @MainActor func selectOpensTheOnlyLinkAndATextWithSeveralIsNotOffered() {
        var opened: [URL] = []
        let one = linkText { opened.append($0) }
        #expect(one.isTappable)
        one.tapped(at: nil)
        #expect(opened == [site])

        let two = Text(
            rich: RichText(
                blocks: [
                    .paragraph([
                        Run("a", link: site), Run(" "),
                        Run("b", link: URL(string: "https://b.example")),
                    ])
                ]
            )
        )
        two.onLink = { _ in }
        #expect(!two.isTappable)
    }

    @Test @MainActor func actionsSetOnATextWithNoLinksAreLeftAlone() {
        let text = Text("plain")
        text.accessibilityActions = [AccessibilityAction(name: "Mine") { true }]
        text.text = "changed"
        #expect(text.accessibilityActions.map(\.name) == ["Mine"])
    }

    // MARK: Drawing

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(
                image,
                in: CGRect(
                    x: -x,
                    y: -(image.height - 1 - y),
                    width: image.width,
                    height: image.height
                )
            )
        }
        return pixel[3]
    }

    @Test @MainActor func aQuoteHasABarAndCodeAPlateAndAParagraphNeither() throws {
        let text = Text(
            rich: RichText(
                blocks: [
                    .paragraph([Run("plain")]), .quote([Run("quoted words")]),
                    .code("code()", language: nil),
                ]
            )
        )
        let (column, host) = laidOut(text, width: 240)
        let renderer = LayerRenderer()
        renderer.render(column, in: CALayer(), scale: 1)
        let image = try #require(renderer.layer(for: column.text)?.contents.map { $0 as! CGImage })

        let placed = RichPlacedLayout(
            blocks: text.rich!.blocks.map {
                RichBlockLayout(
                    $0,
                    width: Double(image.width),
                    metrics: metrics,
                    colors: .measuring
                )
            },
            width: Double(image.width),
            metrics: metrics,
            maxLines: nil
        )
        func middle(_ index: Int) -> Int {
            Int(placed.stack.tops[index] + placed.blocks[index].geometry.height(showing: nil) / 2)
        }
        // The left edge and the far right edge, at the middle of each block.
        #expect(alpha(image, x: 0, y: middle(0)) == 0)
        #expect(alpha(image, x: 1, y: middle(1)) > 0, "the quote's bar")
        #expect(alpha(image, x: image.width - 2, y: middle(1)) == 0)
        #expect(alpha(image, x: image.width - 2, y: middle(2)) > 0, "the code's plate")
        host.detach()
    }

    @Test @MainActor func underlineStrikeAndLinkAddInkToTheSameWords() throws {
        func ink(_ block: RichText.Block) throws -> Int {
            let (column, host) = laidOut(Text(rich: RichText(blocks: [block])), width: 240)
            defer { host.detach() }
            let renderer = LayerRenderer()
            renderer.render(column, in: CALayer(), scale: 1)
            let image = try #require(
                renderer.layer(for: column.text)?.contents.map { $0 as! CGImage }
            )
            var total = 0
            for row in 0..<image.height {
                for x in 0..<image.width where alpha(image, x: x, y: row) > 0 { total += 1 }
            }
            return total
        }
        // The same words in the same font: what is added is the rule.
        let plain = try ink(.paragraph([Run("Underline me")]))
        #expect(try ink(.paragraph([Run("Underline me", marks: .underline)])) > plain)
        #expect(try ink(.paragraph([Run("Underline me", marks: .strike)])) > plain)
        // A link is drawn in another color and underlined: more ink than the plain words, too.
        #expect(try ink(.paragraph([Run("Underline me", link: site)])) > plain)
    }
#endif
