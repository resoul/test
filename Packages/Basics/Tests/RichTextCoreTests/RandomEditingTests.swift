import Foundation
import Testing

@testable import RichTextCore

/// A pseudo-random generator with a fixed seed, so that a failure repeats.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

@Suite struct RandomEditingTests {
    /// Pieces that stress the cutting into characters: joiners, accents, flags, line breaks.
    private let pieces = [
        "a", "b", " ", "\n", "\r\n", "\u{301}", "e", "🇺", "🇸", "👩\u{200D}", "👧", "é", "日本",
        "x\u{308}",
    ]

    private func check(_ text: RichText, after step: String) {
        #expect(!text.blocks.isEmpty, "\(step)")
        #expect(RichText(blocks: text.blocks) == text, "not in normal form after \(step)")
        for (index, block) in text.blocks.enumerated() {
            #expect(block.characterCount == block.text.count)
            #expect(!block.runs.contains { $0.text.isEmpty }, "empty run after \(step)")
            for pair in zip(block.runs, block.runs.dropFirst()) {
                #expect(
                    pair.0.marks != pair.1.marks || pair.0.link != pair.1.link,
                    "runs not joined after \(step)"
                )
            }
            // A run border is a character border of the whole block.
            if case .code = block {
            } else {
                let characters = block.runs.reduce(0) { $0 + $1.text.count }
                #expect(
                    characters == block.characterCount,
                    "run border inside a character after \(step)"
                )
            }
            if case .code(let text, let language) = block {
                #expect(language != "" && !text.contains("\r"), "\(step)")
            }
            for offset in 0...block.characterCount {
                let position = RichPosition(block: index, offset: offset)
                let units = text.utf16Offset(of: position)
                #expect(text.position(utf16Offset: units, rounding: .down) == position)
            }
        }
    }

    @Test func manyRandomEditsKeepTheTextInNormalFormAndItsPositionsValid() {
        var random = Seeded(state: 20_260_929)
        var text = RichText()
        let urls = [URL(string: "https://a.example")!, URL(string: "https://b.example")!]

        for step in 0..<3000 {
            func position() -> RichPosition {
                let block = Int.random(in: 0..<text.blocks.count, using: &random)
                let offset = Int.random(in: 0...text.blocks[block].characterCount, using: &random)
                return RichPosition(block: block, offset: offset)
            }
            let label: String
            switch Int.random(in: 0..<9, using: &random) {
            case 0, 1, 2:
                let piece = pieces.randomElement(using: &random)!
                let attributes =
                    Bool.random(using: &random)
                    ? Attributes(marks: Marks(rawValue: UInt8.random(in: 0..<32, using: &random)))
                    : nil
                let place = position()
                let caret = text.insert(piece, at: place, attributes: attributes)
                #expect(caret.block == place.block)
                #expect(caret == text.clamped(caret))
                label = "insert \(piece.debugDescription) at \(place)"
            case 3:
                let range = RichRange(position(), position())
                let caret = text.delete(range)
                #expect(caret == text.clamped(caret))
                label = "delete \(range)"
            case 4:
                let place = position()
                text.deleteBackward(at: place)
                label = "backspace \(place)"
            case 5:
                let place = position()
                text.splitBlock(at: place)
                label = "return \(place)"
            case 6:
                let range = RichRange(position(), position())
                let before = text.plainText
                text.toggle(
                    Marks(rawValue: 1 << UInt8.random(in: 0..<5, using: &random)),
                    in: range
                )
                #expect(text.plainText == before, "a mark changed the text")
                label = "toggle \(range)"
            case 7:
                let range = RichRange(position(), position())
                let before = text.plainText
                text.setLink(
                    Bool.random(using: &random) ? urls.randomElement(using: &random) : nil,
                    in: range
                )
                #expect(text.plainText == before)
                label = "link \(range)"
            default:
                let range = RichRange(position(), position())
                let kinds: [RichText.Kind] = [.paragraph, .quote, .code(language: "swift")]
                let before = text.plainText
                text.setKind(kinds.randomElement(using: &random)!, for: range)
                #expect(text.plainText == before)
                label = "kind \(range)"
            }
            check(text, after: "step \(step): \(label)")
        }
    }
}
