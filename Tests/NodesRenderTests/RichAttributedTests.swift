#if canImport(UIKit) || (canImport(AppKit) && !canImport(UIKit))
    import Foundation
    import RichTextCore
    import Testing

    #if canImport(UIKit)
        import UIKit

        @testable import NodesUIKit

        private typealias Font = UIFont
        private func isBold(_ font: Font) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.traitBold)
        }
        private func isItalic(_ font: Font) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        }
        private func isMono(_ font: Font) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        }
        private func systemBold(_ size: Double) -> Font { .boldSystemFont(ofSize: size) }
    #else
        import AppKit

        @testable import NodesAppKit

        private typealias Font = NSFont
        private func isBold(_ font: Font) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.bold)
        }
        private func isItalic(_ font: Font) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.italic)
        }
        private func isMono(_ font: Font) -> Bool {
            font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
        private func systemBold(_ size: Double) -> Font { .boldSystemFont(ofSize: size) }
    #endif

    private let site = URL(string: "https://example.com/x")!
    private var style: RichAttributedStyle { .standard }

    private func attributes(_ text: NSAttributedString, at index: Int) -> [NSAttributedString.Key:
        Any]
    {
        text.attributes(at: index, effectiveRange: nil)
    }

    private func font(_ text: NSAttributedString, at index: Int) -> Font {
        attributes(text, at: index)[.font] as! Font
    }

    private let sample = RichText(
        blocks: [
            .paragraph([
                Run("plain "), Run("bold", marks: .bold), Run(" "), Run("italic", marks: .italic),
                Run(" "), Run("mono", marks: .mono), Run(" "), Run("struck", marks: .strike),
                Run(" "), Run("under", marks: .underline), Run(" "), Run("link", link: site),
            ]),
            .quote([Run("quoted\nline")]),
            .code("let a = 1\nlet b = 2", language: "swift"),
        ]
    )

    @Test func theAttributedTextHasTheWordsOfThePlatformText() {
        let text = RichAttributed.attributedString(sample, style: style)
        #expect(text.string == sample.platformText)
        #expect(text.length == sample.plainText.utf16.count)
    }

    @Test func eachMarkBecomesItsAttribute() {
        let text = RichAttributed.attributedString(sample, style: style)
        func index(of word: String) -> Int { (text.string as NSString).range(of: word).location }

        #expect(!isBold(font(text, at: index(of: "plain"))))
        #expect(isBold(font(text, at: index(of: "bold"))))
        #expect(isItalic(font(text, at: index(of: "italic"))))
        #expect(isMono(font(text, at: index(of: "mono"))))
        #expect(font(text, at: index(of: "mono")).pointSize < style.font.pointSize)
        #expect(attributes(text, at: index(of: "struck"))[.strikethroughStyle] as? Int != nil)
        #expect(attributes(text, at: index(of: "under"))[.underlineStyle] as? Int != nil)
        #expect(attributes(text, at: index(of: "link"))[.link] as? URL == site)
        #expect(attributes(text, at: index(of: "plain"))[.link] == nil)
        #expect(attributes(text, at: index(of: "plain"))[.underlineStyle] == nil)
    }

    @Test func boldAndItalicTogetherAreBothTraits() {
        let text = RichAttributed.attributedString(
            RichText(blocks: [.paragraph([Run("both", marks: [.bold, .italic])])]),
            style: style
        )
        #expect(isBold(font(text, at: 0)) && isItalic(font(text, at: 0)))
    }

    @Test func everyCharacterOfABlockCarriesItsKindIncludingTheNewlineThatEndsIt() {
        let text = RichAttributed.attributedString(sample, style: style)
        let tags = (0..<text.length).map {
            attributes(text, at: $0)[RichAttributed.blockKey] as? String
        }
        let string = text.string as NSString
        let quote = string.range(of: "quoted")
        let code = string.range(of: "let a")
        #expect(tags.first! == "p")
        #expect(tags[quote.location] == "q")
        #expect(tags[quote.location - 1] == "p", "the newline before the quote ends the paragraph")
        #expect(tags[code.location - 1] == "q", "the newline before the code ends the quote")
        #expect(tags[code.location] == "c:swift")
        #expect(tags.allSatisfy { $0 != nil })
    }

    @Test func aQuoteIsIndentedAndCodeIsMonospacedOnABackground() {
        let text = RichAttributed.attributedString(sample, style: style)
        let string = text.string as NSString
        let quote = attributes(text, at: string.range(of: "quoted").location)
        let code = attributes(text, at: string.range(of: "let a").location)
        let plain = attributes(text, at: 0)
        #expect((quote[.paragraphStyle] as! NSParagraphStyle).headIndent > 0)
        #expect((plain[.paragraphStyle] as! NSParagraphStyle).headIndent == 0)
        #expect(isMono(code[.font] as! Font))
        #expect(code[.backgroundColor] != nil)
        #expect(plain[.backgroundColor] == nil)
    }

    @Test func aTextSurvivesTheTripToAttributesAndBack() {
        #expect(
            RichAttributed.richText(
                from: RichAttributed.attributedString(sample, style: style),
                style: style
            ) == sample
        )
    }

    @Test func aTextWithEmptyBlocksAndEmojiSurvivesToo() {
        let text = RichText(
            blocks: [
                .paragraph([Run("👩‍👩‍👧 é", marks: [.bold, .italic, .strike])]), .quote([]),
                .paragraph([]),
                .code("", language: nil), .paragraph([Run("end", link: site)]),
            ]
        )
        let back = RichAttributed.richText(
            from: RichAttributed.attributedString(text, style: style),
            style: style
        )
        #expect(back == text)
    }

    @Test func manyRandomTextsSurviveTheTrip() {
        var state: UInt64 = 5
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = ["a", " ", "\n", "é", "🇺🇸", "e\u{301}", "日本", "*"]
        for round in 0..<300 {
            var blocks: [RichText.Block] = []
            for _ in 0..<(1 + next(4)) {
                var text = ""
                for _ in 0..<next(6) { text += pieces[next(pieces.count)] }
                switch next(3) {
                case 0:
                    blocks.append(
                        .paragraph([
                            Run(
                                text,
                                marks: Marks(rawValue: UInt8(next(32))),
                                link: next(2) == 0 ? site : nil
                            )
                        ])
                    )
                case 1: blocks.append(.quote([Run(text, marks: .italic)]))
                default: blocks.append(.code(text, language: next(2) == 0 ? nil : "swift"))
                }
            }
            var value = RichText(blocks: blocks)
            if value.blocks.last!.characterCount == 0 {
                value = RichText(blocks: Array(value.blocks.dropLast()) + [.paragraph([])])
            }
            let back = RichAttributed.richText(
                from: RichAttributed.attributedString(value, style: style),
                style: style
            )
            #expect(back == value, "round \(round): \(value.blocks)")
        }
    }

    @Test func fontsAndMarksFromElsewhereAreRead() {
        // What a paste from another app looks like: system fonts, underline, a link as a string,
        // and no kind at all.
        let foreign = NSMutableAttributedString()
        foreign.append(NSAttributedString(string: "so ", attributes: [.font: style.font]))
        foreign.append(
            NSAttributedString(
                string: "bold",
                attributes: [.font: systemBold(style.font.pointSize), .underlineStyle: 1]
            )
        )
        foreign.append(NSAttributedString(string: "\n", attributes: [.font: style.font]))
        foreign.append(
            NSAttributedString(
                string: "site",
                attributes: [.font: style.font, .link: "https://example.com/x"]
            )
        )
        let text = RichAttributed.richText(from: foreign, style: style)
        #expect(
            text.blocks == [
                .paragraph([Run("so "), Run("bold", marks: [.bold, .underline])]),
                .paragraph([Run("site", link: site)]),
            ]
        )
    }

    @Test func aBaseFontThatIsBoldItselfIsNotReadAsBold() {
        var bold = RichAttributedStyle.standard
        bold.font = systemBold(17)
        let plain = RichText(plain: "all bold by the view's font")
        let text = RichAttributed.attributedString(plain, style: bold)
        #expect(RichAttributed.richText(from: text, style: bold) == plain)
    }

    @Test func aTagIsReadBackToItsKind() {
        for kind: RichText.Kind in [
            .paragraph, .quote, .code(language: nil), .code(language: "c++"),
        ] {
            #expect(RichAttributed.kind(ofTag: RichAttributed.tag(kind)) == kind)
        }
        #expect(RichAttributed.kind(ofTag: "nonsense") == nil)
    }
#endif
