import Foundation
import Testing

@testable import RichTextCore

@Suite struct MarkdownTests {
    private let site = URL(string: "https://example.com/a")!

    private func read(_ markdown: String) -> [RichText.Block] {
        RichText(markdown: markdown).blocks
    }

    // MARK: Reading blocks

    @Test func blankLinesSeparateParagraphsAndLinesInOneKeepTheirBreaks() {
        #expect(
            read("one\ntwo\n\nthree") == [
                .paragraph([Run("one\ntwo")]), .paragraph([Run("three")]),
            ]
        )
        #expect(read("  \n\nx\n\n  \n") == [.paragraph([Run("x")])])
        #expect(read("") == [.paragraph([])])
        #expect(read("a\r\nb\rc") == [.paragraph([Run("a\nb\nc")])])
    }

    @Test func aQuoteIsLinesThatBeginWithAGreaterThanSign() {
        #expect(read("> one\n>two\n>\n> three") == [.quote([Run("one\ntwo\n\nthree")])])
        #expect(read("> a\n\n> b") == [.quote([Run("a")]), .quote([Run("b")])])
        #expect(read(">") == [.quote([])])
        #expect(read("> > inner") == [.quote([Run("> inner")])])
    }

    @Test func aQuoteInterruptsAParagraph() {
        #expect(read("text\n> quoted") == [.paragraph([Run("text")]), .quote([Run("quoted")])])
    }

    @Test func fencedCodeKeepsEverythingAndItsLanguage() {
        #expect(
            read("```swift extra\nlet a = **1**\n\n  indented\n```")
                == [.code("let a = **1**\n\n  indented", language: "swift")]
        )
        #expect(read("```\n```") == [.code("", language: nil)])
        // Only backticks fence code.
        for block in read("~~~\nx\n~~~") {
            if case .code = block { Issue.record("a tilde fence was read as code") }
        }
    }

    @Test func aLongerFenceIsNotClosedByAShorterOne() {
        #expect(read("````\n```\ninside\n```\n````") == [.code("```\ninside\n```", language: nil)])
    }

    @Test func codeWithoutAnEndGoesToTheEndOfTheText() {
        #expect(read("```\nunfinished\ntext") == [.code("unfinished\ntext", language: nil)])
    }

    @Test func aLineWithBackticksAfterTheFenceIsTextNotAFence() {
        #expect(read("```code``` here") == [.paragraph([Run("code", marks: .mono), Run(" here")])])
    }

    @Test func aFenceInterruptsAParagraph() {
        #expect(
            read("text\n```\ncode\n```") == [
                .paragraph([Run("text")]), .code("code", language: nil),
            ]
        )
    }

    @Test func unsupportedSyntaxIsPlainText() {
        #expect(read("# Heading") == [.paragraph([Run("# Heading")])])
        #expect(read("- one\n- two") == [.paragraph([Run("- one\n- two")])])
        #expect(
            read("![alt](x.png)") == [
                .paragraph([Run("!"), Run("alt", link: URL(string: "x.png"))])
            ]
        )
        #expect(read("<b>x</b>") == [.paragraph([Run("<b>x</b>")])])
    }

    // MARK: Reading inline

    @Test func everyMarkIsRead() {
        #expect(
            read("**b** _i_ *j* ~~s~~ `m`")
                == [
                    .paragraph([
                        Run("b", marks: .bold), Run(" "), Run("i", marks: .italic), Run(" "),
                        Run("j", marks: .italic), Run(" "), Run("s", marks: .strike), Run(" "),
                        Run("m", marks: .mono),
                    ])
                ]
        )
    }

    @Test func marksNest() {
        #expect(
            read("**bold _and italic_ text**")
                == [
                    .paragraph([
                        Run("bold ", marks: .bold), Run("and italic", marks: [.bold, .italic]),
                        Run(" text", marks: .bold),
                    ])
                ]
        )
        #expect(
            read("**`code`**") == [.paragraph([Run("code", marks: [.bold, .mono])])]
        )
    }

    @Test func aLinkHoldsMarksAndTheAddressMayHaveParentheses() {
        #expect(
            read("[**see** this](https://example.com/a_(b))")
                == [
                    .paragraph([
                        Run("see", marks: .bold, link: URL(string: "https://example.com/a_(b)")),
                        Run(" this", link: URL(string: "https://example.com/a_(b)")),
                    ])
                ]
        )
        #expect(
            read(#"[x](https://e.com/\(y\))"#)
                == [.paragraph([Run("x", link: URL(string: "https://e.com/(y)"))])]
        )
    }

    @Test func backslashesGiveTheSignItself() {
        #expect(read(#"\*not bold\* \_ \\ \a"#) == [.paragraph([Run(#"*not bold* _ \ \a"#)])])
        #expect(read(#"\> not a quote"#) == [.paragraph([Run("> not a quote")])])
    }

    @Test func aMonospacedSpanCanHoldSignsAndBackticks() {
        #expect(read("`**not bold**`") == [.paragraph([Run("**not bold**", marks: .mono)])])
        #expect(read("`` a`b ``") == [.paragraph([Run("a`b", marks: .mono)])])
        #expect(read("`` `x` ``") == [.paragraph([Run("`x`", marks: .mono)])])
        #expect(read("`  x  `") == [.paragraph([Run(" x ", marks: .mono)])])
    }

    @Test func unfinishedOrMisplacedDelimitersAreText() {
        #expect(read("**open") == [.paragraph([Run("**open")])])
        #expect(read("a ** b ** c") == [.paragraph([Run("a ** b ** c")])])
        #expect(read("snake_case_name") == [.paragraph([Run("snake_case_name")])])
        // An underscore after a letter does not open, and one before a letter does not close.
        #expect(read("a_b_ c") == [.paragraph([Run("a_b_ c")])])
        #expect(read("_a_b") == [.paragraph([Run("_a_b")])])
        #expect(read("[no link](") == [.paragraph([Run("[no link](")])])
        #expect(read("[a] (b)") == [.paragraph([Run("[a] (b)")])])
        #expect(read("`open") == [.paragraph([Run("`open")])])
        #expect(read("~one~") == [.paragraph([Run("~one~")])])
    }

    @Test func aLinkInsideALinkIsText() {
        let blocks = read("[a [b](https://x.example) c](https://y.example)")
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "a [b](https://x.example) c")
    }

    // MARK: Writing

    @Test func blocksAreWrittenSeparatedByABlankLine() {
        let text = RichText(
            blocks: [
                .paragraph([Run("plain")]), .quote([Run("one\n\nthree")]),
                .code("let a = 1", language: "swift"),
            ]
        )
        #expect(text.markdown == "plain\n\n> one\n>\n> three\n\n```swift\nlet a = 1\n```")
    }

    @Test func everyMarkIsWritten() {
        let text = RichText(
            blocks: [
                .paragraph([
                    Run("b", marks: .bold), Run(" "), Run("i", marks: .italic), Run(" "),
                    Run("s", marks: .strike), Run(" "), Run("m", marks: .mono), Run(" "),
                    Run("l", link: site),
                ])
            ]
        )
        #expect(text.markdown == "**b** _i_ ~~s~~ `m` [l](https://example.com/a)")
    }

    @Test func signsInTextAreEscapedAndAQuoteSignAtALineStartToo() {
        let text = RichText(blocks: [.paragraph([Run("*a* _b_ [c] `d` ~e~ \\f\n> g x > y")])])
        #expect(text.markdown == #"\*a\* \_b\_ \[c\] \`d\` \~e\~ \\f"# + "\n" + #"\> g x > y"#)
    }

    @Test func spacesAtTheEdgesOfAMarkedRunGoOutsideTheDelimiters() {
        let text = RichText(blocks: [.paragraph([Run("a"), Run(" bold ", marks: .bold), Run("b")])])
        #expect(text.markdown == "a **bold** b")
    }

    @Test func aRunOfOnlySpacesLosesItsMarks() {
        let text = RichText(blocks: [.paragraph([Run("a"), Run("  ", marks: .bold), Run("b")])])
        #expect(text.markdown == "a  b")
    }

    @Test func italicInsideAWordUsesAsterisks() {
        let text = RichText(blocks: [
            .paragraph([Run("un"), Run("believ", marks: .italic), Run("able")])
        ])
        #expect(text.markdown == "un*believ*able")
        #expect(RichText(markdown: text.markdown) == text)
    }

    @Test func underlineAndAnEmptyParagraphAreNotWritten() {
        let text = RichText(
            blocks: [
                .paragraph([Run("under", marks: .underline)]), .paragraph([]),
                .paragraph([Run("x")]),
            ]
        )
        #expect(text.markdown == "under\n\nx")
    }

    @Test func aLongerFenceThanAnyRunOfBackticksInsideIsUsed() {
        let text = RichText(blocks: [.code("a\n```\nb", language: nil)])
        #expect(text.markdown == "````\na\n```\nb\n````")
        #expect(RichText(markdown: text.markdown) == text)
    }

    @Test func aLanguageThatCannotBeWrittenIsLeftOut() {
        #expect(RichText(blocks: [.code("x", language: "a b")]).markdown == "```\nx\n```")
    }

    @Test func aMonospacedRunWithBackticksAtTheEdgesGetsSpaces() {
        let text = RichText(blocks: [.paragraph([Run("`x`", marks: .mono)])])
        #expect(text.markdown == "`` `x` ``")
        #expect(RichText(markdown: text.markdown) == text)
    }

    // MARK: Round trips

    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state ^ (state >> 29)
        }
    }

    /// Text the dialect can hold: signs that would be syntax, line breaks that are not blank
    /// lines, no edge spaces on a marked run.
    private func randomRuns(_ random: inout Seeded) -> [Run] {
        let plain = ["a b", "x\ny", "*_~[]()\\`>", "é", "1_2", "> q", "#", "- x", "a**b"]
        let cores = ["word", "two words", "*star*", "a_b", "`tick`", "x(y)", "[br]", "日本"]
        let urls = [site, URL(string: "https://e.example/p_(q)")!]
        var runs = [Run(plain.randomElement(using: &random)!)]
        for _ in 0..<Int.random(in: 0...4, using: &random) {
            var marks: Marks = []
            for mark: Marks in [.bold, .italic, .strike, .mono] where Bool.random(using: &random) {
                marks.insert(mark)
            }
            let link = Bool.random(using: &random) ? urls.randomElement(using: &random) : nil
            runs.append(Run(" "))
            runs.append(Run(cores.randomElement(using: &random)!, marks: marks, link: link))
            runs.append(Run(" "))
            runs.append(Run(plain.randomElement(using: &random)!))
        }
        return runs
    }

    @Test func aTextOfTheSupportedSubsetSurvivesWritingAndReading() {
        var random = Seeded(state: 20_260_930)
        for round in 0..<2000 {
            var blocks: [RichText.Block] = []
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                switch Int.random(in: 0..<3, using: &random) {
                case 0: blocks.append(.paragraph(randomRuns(&random)))
                case 1: blocks.append(.quote(randomRuns(&random)))
                default:
                    blocks.append(
                        .code(
                            ["let a = 1", "x\n```\ny", "", "  indented\n\nblank", "*_`"]
                                .randomElement(
                                    using: &random
                                )!,
                            language: [nil, "swift", "c++"].randomElement(using: &random)!
                        )
                    )
                }
            }
            let text = RichText(blocks: blocks)
            let written = text.markdown
            let back = RichText(markdown: written)
            #expect(back == text, "round \(round):\n\(written)\n\(text.blocks)\n\(back.blocks)")
        }
    }

    @Test func readingNeverFailsAndWritingWhatWasReadKeepsEveryWord() {
        var random = Seeded(state: 7)
        let alphabet = Array("ab _*~`[]()\\>\n#-.é1")
        var changedMarks = 0
        for round in 0..<4000 {
            let length = Int.random(in: 0...40, using: &random)
            let source = String((0..<length).map { _ in alphabet.randomElement(using: &random)! })
            let once = RichText(markdown: source)
            let twice = RichText(markdown: once.markdown)
            // The text is what must survive; a run of marks the delimiters cannot keep apart
            // may be written without them.
            #expect(
                twice.plainText.filter { !$0.isWhitespace }
                    == once.plainText.filter { !$0.isWhitespace },
                "round \(round): \(source.debugDescription)"
            )
            if twice != once { changedMarks += 1 }
        }
        // Losing marks is the exception: a few in a thousand of random signs.
        #expect(changedMarks < 40, "\(changedMarks) of 4000 lost marks")
    }

    @Test func aSpanOfBackticksThatWouldReadAsAFenceAtALineStartIsWrittenAsPlainWords() {
        let text = RichText(
            blocks: [.paragraph([Run("a\n"), Run("x\n`` y", marks: .mono), Run(" b")])]
        )
        let back = RichText(markdown: text.markdown)
        #expect(back.plainText == text.plainText)
        #expect(back.blocks.count == 1)
    }

    @Test func textWithoutSyntaxIsReadAsItIs() {
        var random = Seeded(state: 11)
        let alphabet = Array("abc dé1.,!?日")
        for _ in 0..<500 {
            let length = Int.random(in: 1...30, using: &random)
            let source = String((0..<length).map { _ in alphabet.randomElement(using: &random)! })
                .trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { continue }

            #expect(RichText(markdown: source).plainText == source)
        }
    }
}
