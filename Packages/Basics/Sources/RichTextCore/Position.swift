import Foundation

/// A place between two characters of a text: a block and a number of characters from the
/// block's start. Characters are extended grapheme clusters, as `Character` counts them, so a
/// position is never inside an emoji or a letter with its accent.
public struct RichPosition: Sendable, Hashable, Comparable, Codable {
    /// The index of the block.
    public var block: Int
    /// The number of characters before the place, within the block.
    public var offset: Int

    public init(block: Int, offset: Int) {
        self.block = block
        self.offset = offset
    }

    public static func < (lhs: RichPosition, rhs: RichPosition) -> Bool {
        (lhs.block, lhs.offset) < (rhs.block, rhs.offset)
    }
}

/// A selection: the text between two positions. `start` is never after `end`; a range with
/// equal ends is a caret.
public struct RichRange: Sendable, Hashable, Codable {
    public var start: RichPosition
    public var end: RichPosition

    /// Makes a range of two positions given in either order.
    public init(_ first: RichPosition, _ second: RichPosition) {
        start = min(first, second)
        end = max(first, second)
    }

    /// A caret at `position`.
    public init(at position: RichPosition) {
        start = position
        end = position
    }

    public var isEmpty: Bool { start == end }
}

/// Which way a platform offset that falls inside a character is moved.
public enum OffsetRounding: Sendable {
    /// To the start of the character.
    case down
    /// To the end of the character.
    case up
}

extension RichText {
    /// `position` moved to the nearest place the text has: a block that exists, and an offset
    /// from zero to the block's length.
    public func clamped(_ position: RichPosition) -> RichPosition {
        let block = min(max(position.block, 0), blocks.count - 1)
        let offset = min(max(position.offset, 0), blocks[block].characterCount)
        return RichPosition(block: block, offset: offset)
    }

    /// `range` with both ends clamped.
    public func clamped(_ range: RichRange) -> RichRange {
        RichRange(clamped(range.start), clamped(range.end))
    }

    /// Where `position` is in `plainText`, in UTF-16 code units — the unit `NSRange` and
    /// platform text views use. Each block after the first begins one unit after the end of
    /// the one before it, which is the separating `"\n"`.
    public func utf16Offset(of position: RichPosition) -> Int {
        let position = clamped(position)
        var total = 0
        for index in 0..<position.block {
            total += blocks[index].text.utf16.count + 1
        }
        return total + blocks[position.block].text.prefix(position.offset).utf16.count
    }

    /// The position at a UTF-16 offset of `plainText`. An offset outside the text goes to the
    /// nearest end. One inside a character — half of a surrogate pair, or between a letter and
    /// its accent — is moved to the character's start with `.down` and to its end with `.up`,
    /// so that a platform range that does not lie on characters still gives a valid position.
    public func position(utf16Offset: Int, rounding: OffsetRounding) -> RichPosition {
        var rest = max(utf16Offset, 0)
        for (index, block) in blocks.enumerated() {
            let text = block.text
            let length = text.utf16.count
            if rest > length, index < blocks.count - 1 {
                rest -= length + 1
                continue
            }
            var characters = 0
            var start = 0
            for character in text {
                let next = start + character.utf16.count
                if rest <= start { break }
                if rest < next {
                    if rounding == .up { characters += 1 }
                    return RichPosition(block: index, offset: characters)
                }
                characters += 1
                start = next
            }
            return RichPosition(block: index, offset: min(characters, block.characterCount))
        }
        return end
    }

    /// The range of a platform selection given as a location and length in UTF-16 units of
    /// `plainText`: the start rounds down and the end up, so the range covers every character
    /// the platform range touches.
    public func range(utf16Location: Int, length: Int) -> RichRange {
        RichRange(
            position(utf16Offset: utf16Location, rounding: .down),
            position(utf16Offset: utf16Location + max(length, 0), rounding: .up)
        )
    }

    /// The location and length of `range` in UTF-16 units of `plainText`.
    public func utf16Range(of range: RichRange) -> (location: Int, length: Int) {
        let range = clamped(range)
        let start = utf16Offset(of: range.start)
        return (start, utf16Offset(of: range.end) - start)
    }
}
