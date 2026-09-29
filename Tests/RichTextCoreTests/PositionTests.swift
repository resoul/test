import Foundation
import Testing

@testable import RichTextCore

@Suite struct PositionTests {
    /// "a🇺🇸b" is three characters and five UTF-16 units; the flag is a pair of regional
    /// indicators, four units.
    private let flag = RichText(plain: "a🇺🇸b")

    @Test func aPositionIsClampedToTheText() {
        let text = RichText(blocks: [.paragraph([Run("ab")]), .paragraph([Run("c")])])
        #expect(
            text.clamped(RichPosition(block: 9, offset: 9)) == RichPosition(block: 1, offset: 1)
        )
        #expect(
            text.clamped(RichPosition(block: -1, offset: -4)) == RichPosition(block: 0, offset: 0)
        )
        #expect(
            text.clamped(RichPosition(block: 0, offset: 5)) == RichPosition(block: 0, offset: 2)
        )
    }

    @Test func aRangeIsOrdered() {
        let a = RichPosition(block: 0, offset: 3)
        let b = RichPosition(block: 1, offset: 0)
        #expect(RichRange(b, a).start == a)
        #expect(RichRange(b, a).end == b)
    }

    @Test func offsetsCountCharactersNotUnits() {
        #expect(flag.blocks[0].characterCount == 3)
        #expect(flag.utf16Offset(of: RichPosition(block: 0, offset: 2)) == 5)
        #expect(flag.utf16Offset(of: flag.end) == 6)
    }

    @Test func blocksAreSeparatedByOneUnitInThePlatformText() {
        let text = RichText(blocks: [.paragraph([Run("ab")]), .quote([Run("cd")])])
        #expect(text.plainText == "ab\ncd")
        #expect(text.utf16Offset(of: RichPosition(block: 1, offset: 0)) == 3)
        #expect(text.position(utf16Offset: 2, rounding: .down) == RichPosition(block: 0, offset: 2))
        #expect(text.position(utf16Offset: 3, rounding: .down) == RichPosition(block: 1, offset: 0))
        #expect(text.position(utf16Offset: 4, rounding: .down) == RichPosition(block: 1, offset: 1))
    }

    @Test func aPlatformOffsetInsideACharacterRoundsToItsEdge() {
        // Unit 2 is the middle of the flag.
        #expect(flag.position(utf16Offset: 2, rounding: .down) == RichPosition(block: 0, offset: 1))
        #expect(flag.position(utf16Offset: 2, rounding: .up) == RichPosition(block: 0, offset: 2))
        #expect(flag.position(utf16Offset: 1, rounding: .down) == RichPosition(block: 0, offset: 1))
        #expect(flag.position(utf16Offset: 1, rounding: .up) == RichPosition(block: 0, offset: 1))
        #expect(flag.position(utf16Offset: 5, rounding: .up) == RichPosition(block: 0, offset: 2))
    }

    @Test func anAccentInsideItsLetterRoundsToo() {
        let text = RichText(plain: "e\u{301}x")
        #expect(text.position(utf16Offset: 1, rounding: .down) == RichPosition(block: 0, offset: 0))
        #expect(text.position(utf16Offset: 1, rounding: .up) == RichPosition(block: 0, offset: 1))
    }

    @Test func aPlatformOffsetOutsideTheTextGoesToTheNearestEnd() {
        #expect(
            flag.position(utf16Offset: -3, rounding: .down) == RichPosition(block: 0, offset: 0)
        )
        #expect(flag.position(utf16Offset: 99, rounding: .up) == flag.end)
    }

    @Test func aPlatformRangeCoversEveryCharacterItTouches() {
        // Units 2..<3 are inside the flag: the range takes the flag whole.
        let range = flag.range(utf16Location: 2, length: 1)
        #expect(range.start == RichPosition(block: 0, offset: 1))
        #expect(range.end == RichPosition(block: 0, offset: 2))
        #expect(flag.utf16Range(of: range) == (1, 4))
    }

    @Test func everyPositionSurvivesTheTripToUnitsAndBack() {
        let text = RichText(
            blocks: [
                .paragraph([Run("a🇺🇸e\u{301}👩‍👩‍👧b")]), .quote([]), .code("x\ny", language: nil),
            ]
        )
        for block in text.blocks.indices {
            for offset in 0...text.blocks[block].characterCount {
                let position = RichPosition(block: block, offset: offset)
                let units = text.utf16Offset(of: position)
                #expect(text.position(utf16Offset: units, rounding: .down) == position)
                #expect(text.position(utf16Offset: units, rounding: .up) == position)
            }
        }
    }
}
