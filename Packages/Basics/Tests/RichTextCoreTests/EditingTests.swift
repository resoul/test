import Foundation
import Testing

@testable import RichTextCore

@Suite struct EditingTests {
    private let bold = Marks.bold
    private func at(_ block: Int, _ offset: Int) -> RichPosition {
        RichPosition(block: block, offset: offset)
    }
    private func range(_ a: RichPosition, _ b: RichPosition) -> RichRange { RichRange(a, b) }

    // MARK: insert

    @Test func typedTextTakesTheMarksOfTheCharacterBefore() {
        var text = RichText(blocks: [.paragraph([Run("ab", marks: bold), Run("cd")])])
        text.insert("X", at: at(0, 2))
        text.insert("Y", at: at(0, 0))
        #expect(text.blocks == [.paragraph([Run("YabX", marks: bold), Run("cd")])])
    }

    @Test func typedTextAtTheEndOfALinkDoesNotExtendIt() {
        let url = URL(string: "https://a.example")!
        var text = RichText(blocks: [.paragraph([Run("ab", link: url), Run("c")])])
        text.insert("X", at: at(0, 2))
        #expect(text.blocks == [.paragraph([Run("ab", link: url), Run("Xc")])])
    }

    @Test func typedTextInsideALinkJoinsIt() {
        let url = URL(string: "https://a.example")!
        var text = RichText(blocks: [.paragraph([Run("ab", link: url)])])
        text.insert("X", at: at(0, 1))
        #expect(text.blocks == [.paragraph([Run("aXb", link: url)])])
    }

    @Test func insertingWithGivenAttributesUsesThem() {
        var text = RichText(plain: "ab")
        text.insert("X", at: at(0, 1), attributes: Attributes(marks: [.italic]))
        #expect(text.blocks == [.paragraph([Run("a"), Run("X", marks: .italic), Run("b")])])
    }

    @Test func insertReturnsThePlaceAfterTheText() {
        var text = RichText(plain: "ab")
        #expect(text.insert("xyz", at: at(0, 1)) == at(0, 4))
        #expect(text.plainText == "axyzb")
    }

    @Test func aNewlineInsertedStaysInTheBlock() {
        var text = RichText(plain: "ab")
        text.insert("\r\n", at: at(0, 1))
        #expect(text.blocks == [.paragraph([Run("a\nb")])])
    }

    @Test func insertingAnAccentJoinsItToTheLetterAndTheCaretIsAfterBoth() {
        var text = RichText(plain: "ex")
        let caret = text.insert("\u{301}", at: at(0, 1))
        #expect(text.blocks[0].characterCount == 2)
        #expect(caret == at(0, 1))
    }

    @Test func insertingALetterBeforeAnAccentTakesTheAccentAndTheCaretGoesAfterThem() {
        var text = RichText(blocks: [.paragraph([Run("\u{301}x")])])
        let caret = text.insert("e", at: at(0, 0))
        #expect(text.plainText == "e\u{301}x")
        #expect(text.blocks[0].characterCount == 2)
        #expect(caret == at(0, 1))
    }

    @Test func insertingIntoCodeStaysPlain() {
        var text = RichText(blocks: [.code("ab", language: "swift")])
        text.insert("X", at: at(0, 1), attributes: Attributes(marks: .bold))
        #expect(text.blocks == [.code("aXb", language: "swift")])
    }

    // MARK: delete

    @Test func deletingInsideABlock() {
        var text = RichText(blocks: [.paragraph([Run("ab", marks: bold), Run("cd")])])
        let caret = text.delete(range(at(0, 1), at(0, 3)))
        #expect(text.blocks == [.paragraph([Run("a", marks: bold), Run("d")])])
        #expect(caret == at(0, 1))
    }

    @Test func deletingAcrossBlocksJoinsTheRestToTheFirstBlockWhichKeepsItsKind() {
        var text = RichText(
            blocks: [
                .quote([Run("one")]), .paragraph([Run("two")]),
                .paragraph([Run("th"), Run("ree", marks: bold)]),
            ]
        )
        let caret = text.delete(range(at(0, 2), at(2, 2)))
        #expect(text.blocks == [.quote([Run("on"), Run("ree", marks: bold)])])
        #expect(caret == at(0, 2))
    }

    @Test func textJoinedIntoCodeLosesItsMarks() {
        var text = RichText(blocks: [
            .code("ab", language: nil), .paragraph([Run("cd", marks: bold)]),
        ])
        text.delete(range(at(0, 1), at(1, 0)))
        #expect(text.blocks == [.code("acd", language: nil)])
    }

    @Test func codeJoinedIntoAParagraphHasNoMarks() {
        var text = RichText(blocks: [
            .paragraph([Run("a", marks: bold)]), .code("bc", language: nil),
        ])
        text.delete(range(at(0, 1), at(1, 0)))
        #expect(text.blocks == [.paragraph([Run("a", marks: bold), Run("bc")])])
    }

    @Test func deletingAnEmptyRangeChangesNothing() {
        var text = RichText(plain: "ab")
        #expect(text.delete(RichRange(at: at(0, 1))) == at(0, 1))
        #expect(text.plainText == "ab")
    }

    @Test func deletingBetweenTwoPartsThatJoinIntoOneCharacterPutsTheCaretAfterIt() {
        // "e", the flag's first half, an accent: deleting the middle joins the letter and the accent.
        var text = RichText(plain: "e🇺🇸\u{301}")
        #expect(text.blocks[0].characterCount == 2)
        let caret = text.delete(range(at(0, 1), at(0, 2)))
        #expect(text.blocks[0].characterCount == 1)
        #expect(caret == at(0, 1))
    }

    // MARK: Backspace

    @Test func backspaceRemovesTheCharacterBeforeTheCaretAWholeFlagAtATime() {
        var text = RichText(plain: "a🇺🇸")
        #expect(text.deleteBackward(at: at(0, 2)) == at(0, 1))
        #expect(text.plainText == "a")
    }

    @Test func backspaceAtTheStartOfAQuoteMakesItAParagraph() {
        var text = RichText(blocks: [.paragraph([Run("a")]), .quote([Run("b", marks: bold)])])
        #expect(text.deleteBackward(at: at(1, 0)) == at(1, 0))
        #expect(text.blocks == [.paragraph([Run("a")]), .paragraph([Run("b", marks: bold)])])
    }

    @Test func backspaceAtTheStartOfAParagraphJoinsItToTheBlockBefore() {
        var text = RichText(blocks: [.quote([Run("a")]), .paragraph([Run("b")])])
        #expect(text.deleteBackward(at: at(1, 0)) == at(0, 1))
        #expect(text.blocks == [.quote([Run("ab")])])
    }

    @Test func backspaceAtTheStartOfTheTextDoesNothing() {
        var text = RichText(plain: "a")
        #expect(text.deleteBackward(at: at(0, 0)) == at(0, 0))
        #expect(text.plainText == "a")
    }

    @Test func backspaceOnAnEmptyParagraphAfterCodeRemovesTheParagraph() {
        var text = RichText(blocks: [.code("x", language: nil), .paragraph([])])
        #expect(text.deleteBackward(at: at(1, 0)) == at(0, 1))
        #expect(text.blocks == [.code("x", language: nil)])
    }

    // MARK: Return

    @Test func returnInAParagraphSplitsItAndEachHalfKeepsItsStyles() {
        var text = RichText(blocks: [.paragraph([Run("ab", marks: bold), Run("cd")])])
        #expect(text.splitBlock(at: at(0, 3)) == at(1, 0))
        #expect(
            text.blocks == [
                .paragraph([Run("ab", marks: bold), Run("c")]), .paragraph([Run("d")]),
            ]
        )
    }

    @Test func returnAtTheEndOfAParagraphMakesAnEmptyOne() {
        var text = RichText(plain: "ab")
        text.splitBlock(at: at(0, 2))
        #expect(text.blocks == [.paragraph([Run("ab")]), .paragraph([])])
    }

    @Test func returnInAQuoteAddsALineBreak() {
        var text = RichText(blocks: [.quote([Run("ab")])])
        #expect(text.splitBlock(at: at(0, 1)) == at(0, 2))
        #expect(text.blocks == [.quote([Run("a\nb")])])
    }

    @Test func returnOnAnEmptyLastLineOfCodeLeavesTheBlock() {
        var text = RichText(blocks: [.code("ab\n", language: "swift")])
        #expect(text.splitBlock(at: at(0, 3)) == at(1, 0))
        #expect(text.blocks == [.code("ab", language: "swift"), .paragraph([])])
    }

    @Test func returnInAnEmptyQuoteMakesItAParagraph() {
        var text = RichText(blocks: [.quote([])])
        text.splitBlock(at: at(0, 0))
        #expect(text.blocks == [.paragraph([])])
    }

    // MARK: Marks and links

    @Test func toggleAddsAMarkWhenNoneOrSomeHaveIt() {
        var text = RichText(blocks: [.paragraph([Run("ab", marks: bold), Run("cd")])])
        #expect(text.state(of: .bold, in: range(at(0, 0), at(0, 4))) == .some)
        text.toggle(.bold, in: range(at(0, 0), at(0, 4)))
        #expect(text.blocks == [.paragraph([Run("abcd", marks: bold)])])
        #expect(text.state(of: .bold, in: range(at(0, 0), at(0, 4))) == .all)
    }

    @Test func toggleTakesAMarkOffWhenEveryCharacterHasIt() {
        var text = RichText(blocks: [.paragraph([Run("abcd", marks: bold)])])
        text.toggle(.bold, in: range(at(0, 1), at(0, 3)))
        #expect(
            text.blocks == [.paragraph([Run("a", marks: bold), Run("bc"), Run("d", marks: bold)])]
        )
    }

    @Test func toggleTreatsEachMarkOfASetOnItsOwn() {
        var text = RichText(blocks: [.paragraph([Run("ab", marks: bold), Run("cd")])])
        text.toggle([.bold, .italic], in: range(at(0, 0), at(0, 4)))
        // Bold was on for some: it goes on for all. Italic was on for none: it goes on for all.
        #expect(text.blocks == [.paragraph([Run("abcd", marks: [.bold, .italic])])])
    }

    @Test func toggleAcrossBlocksLeavesCodeAlone() {
        var text = RichText(
            blocks: [.paragraph([Run("ab")]), .code("cd", language: nil), .quote([Run("ef")])]
        )
        text.toggle(.italic, in: range(at(0, 1), at(2, 1)))
        #expect(
            text.blocks == [
                .paragraph([Run("a"), Run("b", marks: .italic)]), .code("cd", language: nil),
                .quote([Run("e", marks: .italic), Run("f")]),
            ]
        )
    }

    @Test func toggleOnACaretDoesNothingAndItsStateIsThatOfTheTypedStyle() {
        var text = RichText(blocks: [.paragraph([Run("ab", marks: bold)])])
        text.toggle(.bold, in: RichRange(at: at(0, 1)))
        #expect(text.blocks == [.paragraph([Run("ab", marks: bold)])])
        #expect(text.state(of: .bold, in: RichRange(at: at(0, 1))) == .all)
        #expect(text.state(of: .italic, in: RichRange(at: at(0, 1))) == .none)
    }

    @Test func aMarkChangeKeepsTheTextAndItsPositions() {
        var text = RichText(plain: "a🇺🇸b")
        let before = text.plainText
        text.toggle(.strike, in: range(at(0, 1), at(0, 3)))
        #expect(text.plainText == before)
        #expect(text.blocks[0].characterCount == 3)
    }

    @Test func aLinkIsSetAndTakenOff() {
        let url = URL(string: "https://a.example")!
        var text = RichText(plain: "abcd")
        text.setLink(url, in: range(at(0, 1), at(0, 3)))
        #expect(text.blocks == [.paragraph([Run("a"), Run("bc", link: url), Run("d")])])
        text.setLink(nil, in: range(at(0, 0), at(0, 4)))
        #expect(text.blocks == [.paragraph([Run("abcd")])])
    }

    @Test func aLinkIsNotSetInCode() {
        var text = RichText(blocks: [.code("ab", language: nil)])
        text.setLink(URL(string: "https://a.example"), in: range(at(0, 0), at(0, 2)))
        #expect(text.blocks == [.code("ab", language: nil)])
    }

    // MARK: Kinds

    @Test func aBlockBecomesCodeAndLosesItsMarksForGood() {
        var text = RichText(blocks: [.paragraph([Run("a", marks: bold), Run("b")])])
        text.setKind(.code(language: "swift"), for: RichRange(at: at(0, 0)))
        #expect(text.blocks == [.code("ab", language: "swift")])
        text.setKind(.quote, for: RichRange(at: at(0, 0)))
        #expect(text.blocks == [.quote([Run("ab")])])
    }

    @Test func aRangeMakesEveryBlockItTouchesOfTheNewKind() {
        var text = RichText(blocks: [
            .paragraph([Run("a")]), .paragraph([Run("b")]), .paragraph([Run("c")]),
        ])
        text.setKind(.quote, for: range(at(0, 0), at(1, 1)))
        #expect(text.blocks == [.quote([Run("a")]), .quote([Run("b")]), .paragraph([Run("c")])])
    }
}
