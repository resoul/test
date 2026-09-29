import Foundation
import Testing

@testable import RichTextCore

@Suite struct PlatformTests {
    private let site = URL(string: "https://example.com")!
    private let soft = String(RichText.softBreak)

    @Test func aLineBreakInsideABlockIsASoftBreakAndBlocksAreSeparatedByNewlines() {
        let text = RichText(
            blocks: [.paragraph([Run("a\nb")]), .quote([Run("c")]), .code("d\ne", language: nil)]
        )
        #expect(text.platformText == "a\(soft)b\nc\nd\(soft)e")
        #expect(text.platformText.utf16.count == text.plainText.utf16.count)
    }

    @Test func theRunsCoverThePlatformTextExactly() {
        let text = RichText(
            blocks: [
                .paragraph([Run("one "), Run("two", marks: .bold), Run("\nthree", link: site)]),
                .quote([]), .code("x\ny", language: "swift"), .paragraph([Run("end")]),
            ]
        )
        #expect(text.platformRuns.map(\.text).joined() == text.platformText)
    }

    @Test func everyRunCarriesTheKindOfItsBlockAndSoDoesTheNewlineThatEndsIt() {
        let text = RichText(blocks: [
            .quote([Run("q")]), .code("c", language: "swift"), .paragraph([Run("p")]),
        ])
        let runs = text.platformRuns
        #expect(
            runs.map(\.kind) == [
                .quote, .quote, .code(language: "swift"), .code(language: "swift"), .paragraph,
            ]
        )
        #expect(runs.map(\.text) == ["q", "\n", "c", "\n", "p"])
    }

    @Test func anEmptyBlockThatIsNotLastKeepsItsKindThroughItsNewline() {
        let text = RichText(blocks: [.paragraph([Run("a")]), .quote([]), .paragraph([Run("b")])])
        #expect(RichText(platformRuns: text.platformRuns) == text)
    }

    @Test func textPastedWithoutAKindTakesTheKindOfTheBlockItIsIn() {
        // A quote "ab" ended by a newline of the quote; "XY" was pasted in the middle without
        // a kind, and so was a whole line after it.
        let runs = [
            PlatformRun("a", kind: .quote), PlatformRun("XY"), PlatformRun("b", kind: .quote),
            PlatformRun("\n", kind: .quote),
            PlatformRun("pasted line"), PlatformRun("\n", kind: .quote), PlatformRun("last"),
        ]
        let text = RichText(platformRuns: runs)
        #expect(
            text.blocks == [
                .quote([Run("aXYb")]), .quote([Run("pasted line")]), .paragraph([Run("last")]),
            ]
        )
    }

    @Test func theKindOfTheFirstCharacterWinsOverThatOfTheNewline() {
        let runs = [
            PlatformRun("q", kind: .quote), PlatformRun("\n", kind: .paragraph),
            PlatformRun("p", kind: .paragraph), PlatformRun("\n", kind: .quote),
            PlatformRun("last", kind: .code(language: nil)),
        ]
        #expect(
            RichText(platformRuns: runs).blocks == [
                .quote([Run("q")]), .paragraph([Run("p")]), .code("last", language: nil),
            ]
        )
    }

    @Test func aSoftBreakDoesNotEndABlockAndANewlineDoes() {
        let text = RichText(platformRuns: [PlatformRun("a\(soft)b\nc", kind: .quote)])
        #expect(text.blocks == [.quote([Run("a\nb")]), .quote([Run("c")])])
    }

    @Test func aTextReadBackFromItsRunsIsTheSameText() {
        let text = RichText(
            blocks: [
                .paragraph([
                    Run("plain "), Run("bold", marks: .bold), Run(" "),
                    Run("link", marks: .italic, link: site),
                ]),
                .quote([Run("a\nb", marks: .strike)]),
                .code("let a = 1\nlet b = 2", language: "swift"),
                .paragraph([Run("👩‍👩‍👧 é", marks: [.underline, .mono])]),
            ]
        )
        #expect(RichText(platformRuns: text.platformRuns) == text)
    }

    @Test func aRunWithNoKindAtAllIsAParagraph() {
        #expect(RichText(platformRuns: [PlatformRun("x")]).blocks == [.paragraph([Run("x")])])
        #expect(RichText(platformRuns: []).blocks == [.paragraph([])])
    }

    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state ^ (state >> 29)
        }
    }

    @Test func manyRandomTextsSurviveTheTripThroughRuns() {
        var random = Seeded(state: 31)
        let pieces = ["a", " ", "\n", "é", "🇺🇸", "e\u{301}", "日本", "*"]
        for round in 0..<1500 {
            var blocks: [RichText.Block] = []
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                var text = ""
                for _ in 0..<Int.random(in: 0...6, using: &random) {
                    text += pieces.randomElement(using: &random)!
                }
                switch Int.random(in: 0..<3, using: &random) {
                case 0:
                    blocks.append(
                        .paragraph([
                            Run(
                                text,
                                marks: Marks(rawValue: UInt8.random(in: 0..<32, using: &random)),
                                link: Bool.random(using: &random) ? site : nil
                            )
                        ])
                    )
                case 1: blocks.append(.quote([Run(text, marks: .italic)]))
                default:
                    blocks.append(
                        .code(text, language: [nil, "swift"].randomElement(using: &random)!)
                    )
                }
            }
            var value = RichText(blocks: blocks)
            // A view cannot keep the kind of an empty last block.
            if value.blocks.last!.characterCount == 0 {
                value = RichText(blocks: Array(value.blocks.dropLast()) + [.paragraph([])])
            }
            #expect(
                RichText(platformRuns: value.platformRuns) == value,
                "round \(round): \(value.blocks)"
            )
            #expect(value.platformText.utf16.count == value.plainText.utf16.count)
        }
    }
}
