import Foundation
import Testing

@testable import RichTextCore

@Suite struct NormalFormTests {
    private let bold = Marks.bold

    @Test func anEmptyListOfBlocksIsOneEmptyParagraph() {
        #expect(RichText(blocks: []).blocks == [.paragraph([])])
        #expect(RichText().isEmpty)
    }

    @Test func emptyRunsGoAndNeighboursOfOneStyleJoin() {
        let text = RichText(
            blocks: [
                .paragraph([
                    Run("ab"), Run(""), Run("cd"), Run("e", marks: bold), Run("f", marks: bold),
                ])
            ]
        )
        #expect(text.blocks == [.paragraph([Run("abcd"), Run("ef", marks: bold)])])
    }

    @Test func aLinkIsPartOfTheStyleThatJoinsRuns() {
        let a = URL(string: "https://a.example")!
        let b = URL(string: "https://b.example")!
        let text = RichText(
            blocks: [.paragraph([Run("x", link: a), Run("y", link: a), Run("z", link: b)])]
        )
        #expect(text.blocks == [.paragraph([Run("xy", link: a), Run("z", link: b)])])
    }

    @Test func aBlockKeepsItselfEmptyWhenItHasNoText() {
        let text = RichText(blocks: [.paragraph([]), .quote([Run("")]), .code("", language: "")])
        #expect(text.blocks == [.paragraph([]), .quote([]), .code("", language: nil)])
    }

    @Test func aBorderInsideACharacterMovesToItsEdgeAndTheFirstScalarGivesTheStyle() {
        // "e" in bold and the accent in plain text are one character, and it is bold.
        let text = RichText(blocks: [.paragraph([Run("e", marks: bold), Run("\u{301}x")])])
        #expect(text.blocks == [.paragraph([Run("e\u{301}", marks: bold), Run("x")])])
        #expect(text.blocks[0].characterCount == 2)
    }

    @Test func lineBreaksBecomeNewlines() {
        let text = RichText(blocks: [
            .paragraph([Run("a\r\nb\rc")]), .code("x\r\ny", language: nil),
        ])
        #expect(text.blocks == [.paragraph([Run("a\nb\nc")]), .code("x\ny", language: nil)])
    }

    @Test func aLineBreakSplitAcrossTwoRunsIsOneBreak() {
        let text = RichText(blocks: [.paragraph([Run("a\r"), Run("\nb", marks: bold)])])
        #expect(text.plainText == "a\nb")
    }

    @Test func codeHasNoMarksAndAnUnknownMarkBitIsDropped() {
        let text = RichText(
            blocks: [.paragraph([Run("a", marks: Marks(rawValue: 0xFF))])]
        )
        #expect(text.blocks == [.paragraph([Run("a", marks: .all)])])
    }

    @Test func normalizingTwiceChangesNothing() {
        let once = RichText(
            blocks: [.paragraph([Run("a", marks: bold), Run("\u{301}"), Run("b")]), .quote([])]
        )
        #expect(RichText(blocks: once.blocks) == once)
    }

    @Test func decodingBringsAWrittenDocumentToNormalForm() throws {
        let json = """
            {"blocks":[{"type":"paragraph","runs":[{"text":"a","marks":0},{"text":"","marks":1},\
            {"text":"b","marks":0}]},{"type":"code","text":"x\\r\\ny","language":""}]}
            """
        let text = try JSONDecoder().decode(RichText.self, from: Data(json.utf8))
        #expect(text.blocks == [.paragraph([Run("ab")]), .code("x\ny", language: nil)])
    }

    @Test func decodingEmptyBlocksGivesOneParagraph() throws {
        let text = try JSONDecoder().decode(RichText.self, from: Data(#"{"blocks":[]}"#.utf8))
        #expect(text.blocks == [.paragraph([])])
    }

    @Test func anUnknownBlockTypeFailsToDecode() {
        let json = #"{"blocks":[{"type":"table"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RichText.self, from: Data(json.utf8))
        }
    }

    @Test func aTextSurvivesEncodingAndDecodingExactly() throws {
        let url = URL(string: "https://example.com/a?b=c")!
        let text = RichText(
            blocks: [
                .paragraph([
                    Run("plain "), Run("bold", marks: [.bold, .underline]), Run("🇺🇸", link: url),
                ]),
                .quote([Run("quoted", marks: .italic)]),
                .code("let x = 1\n", language: "swift"),
                .paragraph([]),
            ]
        )
        let data = try JSONEncoder().encode(text)
        #expect(try JSONDecoder().decode(RichText.self, from: data) == text)
    }
}
