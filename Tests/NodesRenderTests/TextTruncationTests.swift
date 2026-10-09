#if canImport(CoreText)
    import CoreGraphics
    import CoreText
    import Foundation
    import LayoutCore
    import Nodes
    import QuartzCore
    import RichTextCore
    import Testing

    @testable import NodesRender

    private let sentence =
        "The quick brown fox jumps over the lazy dog and keeps on running far away"

    @MainActor
    private final class Page: Node {
        let text: Text

        init(_ text: Text) {
            self.text = text
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { text }.alignItems(.start)
        }
    }

    @MainActor
    private func laidOut(_ text: Text, width: Double = 140) -> (page: Page, host: NodeHost) {
        let page = Page(text)
        let host = NodeHost(root: page, size: LayoutSize(width: width, height: 400))
        host.layoutIfNeeded()
        return (page, host)
    }

    private func oneLine(_ text: String = sentence, factors: [Double] = []) -> TextStyle {
        var style = TextStyle()
        style.maxLines = 1
        style.fitScaleFactors = factors
        return style
    }

    /// The pixels of the image a text draws.
    @MainActor
    private func pixels(of text: Text, in page: Page, host: NodeHost) throws -> Data {
        let renderer = LayerRenderer()
        renderer.render(page, in: CALayer(), scale: 1)
        let image = try #require(renderer.layer(for: text)?.contents) as! CGImage
        return try #require(image.dataProvider?.data) as Data
    }

    // MARK: Token and message

    @Test @MainActor
    func aTextThatFitsIsNotTruncatedAndALongOneIs() {
        let short = Text("Hi", style: oneLine())
        let long = Text(sentence, style: oneLine())
        let (_, shortHost) = laidOut(short)
        let (_, longHost) = laidOut(long)

        #expect(!short.isTruncated)
        #expect(long.isTruncated)
        shortHost.detach()
        longHost.detach()
    }

    @Test @MainActor
    func theTokenIsWhatEndsTheCutLine() throws {
        let plain = Text(sentence, style: oneLine())
        var wide = oneLine()
        wide.truncationToken = "WWWW"
        let changed = Text(sentence, style: wide)
        let (plainPage, plainHost) = laidOut(plain)
        let (widePage, wideHost) = laidOut(changed)

        let before = try pixels(of: plain, in: plainPage, host: plainHost)
        let after = try pixels(of: changed, in: widePage, host: wideHost)

        #expect(before != after)
        plainHost.detach()
        wideHost.detach()
    }

    @Test @MainActor
    func theMessageSitsAtTheEndOfTheLastLineOfACutText() throws {
        let text = Text(sentence, style: oneLine())
        text.truncationMessage = "More"
        let (_, host) = laidOut(text)
        let layout = TextLayout(
            text: sentence,
            style: text.style,
            message: "More",
            messageColor: nil
        )

        let rect = try #require(layout.truncationMessageRect(forWidth: 140))

        #expect(rect.width > 10)
        #expect(rect.maxX <= 140.5)
        #expect(rect.maxX > 100, "at the end of the line, not at its start")
        #expect(rect.minY > -1, "the first line starts at the top, give or take rounding")
        #expect(rect.height > 5 && rect.height < 30)
        host.detach()
    }

    @Test @MainActor
    func aTextThatIsNotCutHasNoMessage() {
        let layout = TextLayout(
            text: "Hi",
            style: oneLine(),
            message: "More",
            messageColor: nil
        )

        #expect(layout.truncationMessageRect(forWidth: 140) == nil)
    }

    @Test @MainActor
    func aTextWithoutAMessageHasNoMessageRect() {
        let layout = TextLayout(text: sentence, style: oneLine())

        #expect(layout.truncationMessageRect(forWidth: 140) == nil)
    }

    @Test @MainActor
    func theMessageChangesWhatIsDrawn() throws {
        let plain = Text(sentence, style: oneLine())
        let withMessage = Text(sentence, style: oneLine())
        withMessage.truncationMessage = "More"
        let (plainPage, plainHost) = laidOut(plain)
        let (messagePage, messageHost) = laidOut(withMessage)

        let before = try pixels(of: plain, in: plainPage, host: plainHost)
        let after = try pixels(of: withMessage, in: messagePage, host: messageHost)

        #expect(before != after)
        plainHost.detach()
        messageHost.detach()
    }

    @Test @MainActor
    func aTapOnTheMessageIsAnsweredAndATapOnTheRestIsNot() throws {
        let text = Text(sentence, style: oneLine())
        text.truncationMessage = "More"
        var taps = 0
        text.onTruncationMessageTap = { taps += 1 }
        let (page, host) = laidOut(text)
        let rect = try #require(
            TextLayout(text: sentence, style: text.style, message: "More", messageColor: nil)
                .truncationMessageRect(forWidth: text.frame.size.width)
        )
        let on = LayoutPoint(
            x: text.frame.origin.x + Double(rect.midX),
            y: text.frame.origin.y + Double(rect.midY)
        )
        let off = LayoutPoint(x: text.frame.origin.x + 4, y: text.frame.origin.y + 4)
        var behind = 0
        page.onTap = { behind += 1 }

        #expect(host.pointerDown(at: on))
        host.pointerUp(at: on)
        #expect(taps == 1)

        host.pointerDown(at: off)
        host.pointerUp(at: off)
        #expect(taps == 1)
        #expect(behind == 1, "the rest of the text leaves the tap to what is behind it")
        host.detach()
    }

    @Test @MainActor
    func theMessageShowsHighlightedWhilePressedAndPlainAfter() throws {
        let text = Text(sentence, style: oneLine())
        text.truncationMessage = "More"
        text.onTruncationMessageTap = {}
        let (page, host) = laidOut(text)
        let rect = try #require(
            TextLayout(text: sentence, style: text.style, message: "More", messageColor: nil)
                .truncationMessageRect(forWidth: text.frame.size.width)
        )
        let on = LayoutPoint(
            x: text.frame.origin.x + Double(rect.midX),
            y: text.frame.origin.y + Double(rect.midY)
        )
        let resting = try pixels(of: text, in: page, host: host)

        host.pointerDown(at: on)
        let pressed = try pixels(of: text, in: page, host: host)
        host.pointerUp(at: on)
        let released = try pixels(of: text, in: page, host: host)

        #expect(pressed != resting)
        #expect(released == resting)
        host.detach()
    }

    // MARK: Fitting

    @Test @MainActor
    func theFirstFactorThatFitsIsUsed() {
        let style = oneLine(factors: [1, 0.75, 0.5, 0.25])
        let width = TextLayout(text: sentence, style: oneLine()).lineWidth(sentence) * 0.6

        let fitted = TextLayout.fitted(style: style, text: sentence, width: width)

        #expect(
            fitted.size == style.size * 0.5,
            "0.75 is still too wide, 0.5 is the first that fits"
        )
        #expect(!TextLayout(text: sentence, style: fitted).isTruncated(forWidth: width))
    }

    @Test @MainActor
    func aTextThatFitsKeepsItsSize() {
        let style = oneLine(factors: [1, 0.5])

        let fitted = TextLayout.fitted(style: style, text: "Hi", width: 200)

        #expect(fitted.size == style.size)
    }

    @Test @MainActor
    func whenNoFactorFitsTheSmallestIsUsedAndTheTextIsCut() {
        let style = oneLine(factors: [0.9, 0.8, 0.7])

        let fitted = TextLayout.fitted(style: style, text: sentence, width: 60)

        #expect(fitted.size == style.size * 0.7)
        #expect(TextLayout(text: sentence, style: fitted).isTruncated(forWidth: 60))
    }

    @Test @MainActor
    func factorsDoNothingWithoutMaxLines() {
        var style = TextStyle()
        style.fitScaleFactors = [0.5]

        #expect(TextLayout.fitted(style: style, text: sentence, width: 60).size == style.size)
    }

    @Test @MainActor
    func theLineSpacingShrinksWithTheSize() {
        var style = oneLine(factors: [0.5])
        style.lineSpacing = 10

        let fitted = TextLayout.fitted(style: style, text: sentence, width: 60)

        #expect(fitted.lineSpacing == 5)
    }

    @Test @MainActor
    func aShrunkTextTakesTheHeightOfItsSmallerFont() {
        let plain = Text(sentence, style: oneLine())
        let shrinking = Text(sentence, style: oneLine(factors: [0.5]))
        let (_, plainHost) = laidOut(plain)
        let (_, shrinkingHost) = laidOut(shrinking)

        #expect(shrinking.frame.size.height < plain.frame.size.height)
        #expect(!shrinking.isTruncated || shrinking.frame.size.height < plain.frame.size.height)
        plainHost.detach()
        shrinkingHost.detach()
    }

    // MARK: Rich text

    @Test @MainActor
    func aRichTextIsTruncatedWhenMaxLinesCutsIt() {
        let rich = RichText(blocks: [.paragraph([Run(sentence)])])
        let cut = Text(rich: rich, style: oneLine())
        let whole = Text(rich: rich)
        let (_, cutHost) = laidOut(cut)
        let (_, wholeHost) = laidOut(whole)

        #expect(cut.isTruncated)
        #expect(!whole.isTruncated)
        cutHost.detach()
        wholeHost.detach()
    }

    @Test @MainActor
    func aPressedLinkShowsHighlightedUntilItIsLetGo() throws {
        let site = URL(string: "https://example.test")!
        let text = Text(
            rich: RichText(
                blocks: [.paragraph([Run("Read "), Run("the page", link: site), Run(" for more")])]
            )
        )
        text.onLink = { _ in }
        let (page, host) = laidOut(text, width: 300)
        // The "t" of "the page" is some way into the line, after "Read ".
        let on = LayoutPoint(x: text.frame.origin.x + 48, y: text.frame.origin.y + 8)
        let resting = try pixels(of: text, in: page, host: host)

        #expect(host.pointerDown(at: on))
        let pressed = try pixels(of: text, in: page, host: host)
        host.pointerUp(at: on)
        let released = try pixels(of: text, in: page, host: host)

        #expect(pressed != resting)
        #expect(released == resting)
        host.detach()
    }
#endif
