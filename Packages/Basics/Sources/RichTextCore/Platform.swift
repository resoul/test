import Foundation

/// A stretch of a platform text view's text that has one style and belongs to one block: what
/// an adapter reads out of the view's attributed text, and writes into it.
public struct PlatformRun: Sendable, Hashable {
    /// The text, in the platform's spelling: blocks are separated by `"\n"`, and a line break
    /// inside a block is `RichText.softBreak`.
    public var text: String
    public var attributes: Attributes
    /// The kind of the block the text is in, when the view keeps it; `nil` when it does not,
    /// as for text pasted from elsewhere.
    public var kind: RichText.Kind?

    public init(_ text: String, attributes: Attributes = Attributes(), kind: RichText.Kind? = nil) {
        self.text = text
        self.attributes = attributes
        self.kind = kind
    }
}

extension RichText {
    /// The line break inside a block in platform text. Text views treat it as a break within a
    /// paragraph, and `"\n"` as the end of one, so a block stays one paragraph however many
    /// lines it has. It is one UTF-16 unit, like `"\n"`, so the offsets of `plainText` hold.
    public static let softBreak: Character = "\u{2028}"

    /// The text as a platform text view holds it: `plainText` with each line break inside a
    /// block spelled `softBreak`. Its UTF-16 length is that of `plainText`, and
    /// `utf16Offset(of:)` and `position(utf16Offset:rounding:)` count in it.
    public var platformText: String {
        blocks.map { $0.text.replacingOccurrences(of: "\n", with: String(RichText.softBreak)) }
            .joined(separator: "\n")
    }

    /// The text cut into runs for a platform text view, covering `platformText` exactly. Each
    /// block's runs carry the block's kind, and the `"\n"` after a block — which belongs to it
    /// — does too, so that an empty block that is not the last is still a block with a kind.
    /// The last block, when empty, has no run and so no kind: a view cannot keep it.
    public var platformRuns: [PlatformRun] {
        var result: [PlatformRun] = []
        for (index, block) in blocks.enumerated() {
            let kind = block.kind
            switch block {
            case .paragraph(let runs), .quote(let runs):
                for run in runs {
                    result.append(
                        PlatformRun(
                            run.text.replacingOccurrences(of: "\n", with: String(Self.softBreak)),
                            attributes: Attributes(marks: run.marks, link: run.link),
                            kind: kind
                        )
                    )
                }
            case .code(let text, _):
                if !text.isEmpty {
                    result.append(
                        PlatformRun(
                            text.replacingOccurrences(of: "\n", with: String(Self.softBreak)),
                            kind: kind
                        )
                    )
                }
            }
            if index < blocks.count - 1 {
                result.append(PlatformRun("\n", kind: kind))
            }
        }
        return result
    }

    /// Makes a text from what a platform text view holds: runs in order, over the whole of its
    /// text. A `"\n"` ends a block and a `softBreak` is a line break inside one. A block's kind
    /// is the kind of its first character, or, when that has none, of the `"\n"` that ends it,
    /// or else a paragraph — so text pasted into a quote stays in the quote.
    public init(platformRuns runs: [PlatformRun]) {
        var blocks: [Block] = []
        var pending: [Run] = []
        var firstKind: Kind?
        var sawCharacter = false

        func finish(endedBy terminator: Kind?) {
            let kind = firstKind ?? terminator ?? .paragraph
            switch kind {
            case .paragraph: blocks.append(.paragraph(pending))
            case .quote: blocks.append(.quote(pending))
            case .code(let language):
                blocks.append(.code(pending.map(\.text).joined(), language: language))
            }
            pending = []
            firstKind = nil
            sawCharacter = false
        }

        for run in runs {
            var buffer = ""
            func flush() {
                guard !buffer.isEmpty else { return }

                pending.append(Run(buffer, marks: run.attributes.marks, link: run.attributes.link))
                buffer = ""
            }
            for character in run.text {
                if character == "\n" {
                    flush()
                    finish(endedBy: run.kind)
                } else {
                    if !sawCharacter {
                        sawCharacter = true
                        firstKind = run.kind
                    }
                    buffer.append(character == Self.softBreak ? "\n" : character)
                }
            }
            flush()
        }
        finish(endedBy: nil)
        self.init(blocks: blocks)
    }
}
