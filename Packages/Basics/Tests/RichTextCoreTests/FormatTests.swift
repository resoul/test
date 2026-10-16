import Foundation
import Testing

@testable import RichTextCore

@Suite struct FormatTests {
    private let site = URL(string: "https://example.com")!
    private func at(_ block: Int, _ offset: Int) -> RichPosition {
        RichPosition(block: block, offset: offset)
    }
    private func range(_ a: RichPosition, _ b: RichPosition) -> RichRange { RichRange(a, b) }

    // MARK: Marks

    @Test func aMarkFormatTogglesItsMarkOverTheSelection() {
        var text = RichText(plain: "abcd")
        text.apply(.bold, in: range(at(0, 1), at(0, 3)))
        #expect(text.blocks == [.paragraph([Run("a"), Run("bc", marks: .bold), Run("d")])])
        #expect(text.state(ofFormat: .bold, in: range(at(0, 1), at(0, 3))) == .all)

        text.apply(.bold, in: range(at(0, 1), at(0, 3)))
        #expect(text.blocks == [.paragraph([Run("abcd")])])
    }

    @Test func aMixedSelectionGetsTheMarkAndThenLosesIt() {
        var text = RichText(blocks: [.paragraph([Run("ab", marks: .italic), Run("cd")])])
        let whole = range(at(0, 0), at(0, 4))
        #expect(text.state(ofFormat: .italic, in: whole) == .some)
        text.apply(.italic, in: whole)
        #expect(text.blocks == [.paragraph([Run("abcd", marks: .italic)])])
        text.apply(.italic, in: whole)
        #expect(text.blocks == [.paragraph([Run("abcd")])])
    }

    @Test func everyMarkFormatMapsToItsOwnMark() {
        let marks = RichFormat.allCases.compactMap(\.mark)
        #expect(Set(marks.map(\.rawValue)).count == 5)
        #expect(Marks(marks) == .all)
        #expect(RichFormat.link.mark == nil)
        #expect(RichFormat.quote.mark == nil)
    }

    @Test func aMarkAtACaretChangesNothingInTheValue() {
        var text = RichText(plain: "ab")
        text.apply(.bold, in: RichRange(at: at(0, 1)))
        #expect(text == RichText(plain: "ab"))
        #expect(text.isAvailable(.bold, in: RichRange(at: at(0, 1))))
    }

    @Test func codeCannotBeMarkedOrLinked() {
        var text = RichText(blocks: [.code("let a", language: nil)])
        let whole = range(at(0, 0), at(0, 5))
        #expect(!text.isAvailable(.bold, in: whole))
        #expect(!text.isAvailable(.link, in: whole))
        #expect(text.isAvailable(.quote, in: whole))
        text.apply(.bold, in: whole)
        text.apply(.link, in: whole, link: site)
        #expect(text.blocks == [.code("let a", language: nil)])
    }

    @Test func aSelectionAcrossCodeAndAParagraphMarksOnlyTheParagraph() {
        var text = RichText(blocks: [.code("ab", language: nil), .paragraph([Run("cd")])])
        let whole = range(at(0, 0), at(1, 2))
        #expect(text.isAvailable(.bold, in: whole))
        text.apply(.bold, in: whole)
        #expect(text.blocks == [.code("ab", language: nil), .paragraph([Run("cd", marks: .bold)])])
    }

    // MARK: Links

    @Test func aLinkNeedsCharactersAndIsPutOnAndTakenOff() {
        var text = RichText(plain: "abcd")
        #expect(!text.isAvailable(.link, in: RichRange(at: at(0, 2))))

        let middle = range(at(0, 1), at(0, 3))
        text.apply(.link, in: middle, link: site)
        #expect(text.blocks == [.paragraph([Run("a"), Run("bc", link: site), Run("d")])])
        #expect(text.link(in: middle) == site)
        #expect(text.state(ofFormat: .link, in: middle) == .all)
        #expect(text.state(ofFormat: .link, in: range(at(0, 0), at(0, 4))) == .none)

        text.apply(.link, in: middle, link: nil)
        #expect(text.blocks == [.paragraph([Run("abcd")])])
    }

    @Test func aRangeWithDifferentLinksHasNoLinkOfItsOwn() {
        let other = URL(string: "https://other.example")!
        let text = RichText(
            blocks: [.paragraph([Run("ab", link: site), Run("cd", link: other), Run("ef")])]
        )
        #expect(text.link(in: range(at(0, 0), at(0, 2))) == site)
        #expect(text.link(in: range(at(0, 0), at(0, 4))) == nil)
        #expect(text.link(in: range(at(0, 1), at(0, 5))) == nil)
        #expect(text.link(in: RichRange(at: at(0, 1))) == nil)
    }

    // MARK: Kinds

    @Test func aKindIsPutOnEveryTouchedBlockAndTakenOffWhenAllHaveIt() {
        var text = RichText(blocks: [
            .paragraph([Run("a")]), .quote([Run("b")]), .paragraph([Run("c")]),
        ])
        let whole = range(at(0, 0), at(2, 1))
        #expect(text.state(ofFormat: .quote, in: whole) == .some)
        text.apply(.quote, in: whole)
        #expect(text.blocks == [.quote([Run("a")]), .quote([Run("b")]), .quote([Run("c")])])
        #expect(text.state(ofFormat: .quote, in: whole) == .all)

        text.apply(.quote, in: whole)
        #expect(
            text.blocks == [.paragraph([Run("a")]), .paragraph([Run("b")]), .paragraph([Run("c")])]
        )
    }

    @Test func aBlockThatHasTheKindKeepsItsLanguage() {
        var text = RichText(blocks: [.code("a", language: "swift"), .paragraph([Run("b")])])
        text.apply(.code, in: range(at(0, 0), at(1, 1)))
        #expect(text.blocks == [.code("a", language: "swift"), .code("b", language: nil)])

        text.apply(.code, in: range(at(0, 0), at(1, 1)))
        #expect(text.blocks == [.paragraph([Run("a")]), .paragraph([Run("b")])])
    }

    @Test func aQuoteBecomingCodeLosesItsMarksAndCodeBecomingAQuoteHasNone() {
        var text = RichText(blocks: [.quote([Run("a", marks: .bold)])])
        text.apply(.code, in: RichRange(at: at(0, 0)))
        #expect(text.blocks == [.code("a", language: nil)])
        text.apply(.quote, in: RichRange(at: at(0, 0)))
        #expect(text.blocks == [.quote([Run("a")])])
    }

    @Test func aKindOnAnEmptyBlockAtTheEndIsKept() {
        var text = RichText(blocks: [.paragraph([Run("a")]), .paragraph([])])
        text.apply(.quote, in: RichRange(at: at(1, 0)))
        #expect(text.blocks == [.paragraph([Run("a")]), .quote([])])
    }

    @Test func aRangePastTheTextIsClamped() {
        var text = RichText(plain: "ab")
        text.apply(.bold, in: range(at(0, 0), at(9, 9)))
        #expect(text.blocks == [.paragraph([Run("ab", marks: .bold)])])
    }

    // MARK: Typed addresses

    @Test func whatIsTypedAsAnAddressBecomesAURL() {
        #expect(RichFormat.linkURL(from: "example.com") == URL(string: "https://example.com"))
        #expect(
            RichFormat.linkURL(from: " http://a.example/x ") == URL(string: "http://a.example/x")
        )
        #expect(
            RichFormat.linkURL(from: "mailto:me@a.example") == URL(string: "mailto:me@a.example")
        )
        #expect(
            RichFormat.linkURL(from: "localhost:8080") == URL(string: "https://localhost:8080")
        )
        #expect(RichFormat.linkURL(from: "  ") == nil)
        #expect(RichFormat.linkURL(from: "two words") == nil)
    }
}
