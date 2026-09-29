import Foundation

/// Styled text as a value: a list of blocks — paragraphs, quotes and code — whose text is
/// cut into runs of one style.
///
/// The value is always in normal form, so that `==` compares what the text says and not how it
/// was written down:
///
/// - There is at least one block; an empty text is one empty paragraph. Empty blocks are
///   otherwise kept, because an editor needs them.
/// - A run is never empty, and two neighbouring runs never share marks and link: they are
///   one run.
/// - Run borders lie between characters, never inside one. Where the borders of the text a
///   caller wrote fall inside a character (a base letter and its accent in two runs), the
///   whole character takes the style of its first scalar.
/// - Line breaks inside a block are `"\n"`; `"\r\n"` and `"\r"` become `"\n"`.
/// - Code holds plain text: it has no marks and no links.
///
/// The initializers, the operations and decoding all end in this form, and `blocks` can be
/// read but not set, so no other value exists. The type is a value and can be used from any
/// thread. It knows nothing of colors or fonts: those come from the theme when the text is
/// shown.
///
/// Every position and range an operation takes is clamped to the text first, so a stale
/// selection cannot crash it; a clamped position is the nearest valid one.
public struct RichText: Sendable, Hashable {
    /// One paragraph-level part of the text.
    public enum Block: Sendable, Hashable {
        /// Ordinary text; a `"\n"` inside is a line break, not a new block.
        case paragraph([Run])
        /// A quotation; its text is set off from the rest.
        case quote([Run])
        /// Text set as it was written, in a monospaced font, without marks. `language` names
        /// the language of the code when it is known.
        case code(String, language: String?)
    }

    /// What kind a block is, without its content.
    public enum Kind: Sendable, Hashable {
        case paragraph
        case quote
        case code(language: String?)
    }

    /// The blocks, in normal form and never empty.
    public internal(set) var blocks: [Block]

    /// Makes a text of `blocks`, in normal form: see the type's description. An empty list
    /// gives one empty paragraph.
    public init(blocks: [Block]) {
        self.blocks = blocks.isEmpty ? [.paragraph([])] : blocks.map { $0.normalized() }
    }

    /// Makes a text of one paragraph with no marks; `"\n"` in `plain` is a line break inside
    /// it.
    public init(plain: String) {
        self.init(blocks: [.paragraph([Run(plain)])])
    }

    /// The empty text: one empty paragraph.
    public init() {
        self.init(blocks: [])
    }

    /// Whether the text has no characters at all.
    public var isEmpty: Bool { blocks.allSatisfy { $0.characterCount == 0 } }

    /// The text without styles: the blocks' texts, one after another and separated by
    /// `"\n"`. This is the text a platform text view holds; see `utf16Offset(of:)`.
    public var plainText: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    /// The position after the last character.
    public var end: RichPosition {
        RichPosition(block: blocks.count - 1, offset: blocks[blocks.count - 1].characterCount)
    }

    /// Replaces the blocks in `range` with `new`, in normal form.
    mutating func replaceBlocks(_ range: Range<Int>, with new: [Block]) {
        blocks.replaceSubrange(range, with: new.map { $0.normalized() })
        if blocks.isEmpty { blocks = [.paragraph([])] }
    }
}

/// A piece of text in one style.
public struct Run: Sendable, Hashable, Codable {
    /// The text of the run; never empty in a normal-form text.
    public var text: String
    /// How the text is set.
    public var marks: Marks
    /// Where the text leads, if it is a link.
    public var link: URL?

    public init(_ text: String, marks: Marks = [], link: URL? = nil) {
        self.text = text
        self.marks = marks
        self.link = link
    }
}

/// The ways a run can be set apart from the text around it.
public struct Marks: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bold = Marks(rawValue: 1 << 0)
    public static let italic = Marks(rawValue: 1 << 1)
    /// Monospaced, as code inside a line.
    public static let mono = Marks(rawValue: 1 << 2)
    public static let strike = Marks(rawValue: 1 << 3)
    public static let underline = Marks(rawValue: 1 << 4)

    /// Every mark there is; decoding drops bits outside it.
    public static let all: Marks = [.bold, .italic, .mono, .strike, .underline]

    /// The marks one by one, for the operations that treat each on its own.
    var singles: [Marks] { [.bold, .italic, .mono, .strike, .underline].filter(contains) }
}

/// The style a character has, or that new text is typed in.
public struct Attributes: Sendable, Hashable {
    public var marks: Marks
    public var link: URL?

    public init(marks: Marks = [], link: URL? = nil) {
        self.marks = marks
        self.link = link
    }

    static let plain = Attributes()
}

extension RichText.Block {
    /// The kind of the block.
    public var kind: RichText.Kind {
        switch self {
        case .paragraph: .paragraph
        case .quote: .quote
        case .code(_, let language): .code(language: language)
        }
    }

    /// The text of the block, without styles.
    public var text: String {
        switch self {
        case .paragraph(let runs), .quote(let runs): runs.map(\.text).joined()
        case .code(let text, _): text
        }
    }

    /// How many characters — extended grapheme clusters, as `Character` counts them — the
    /// block has.
    public var characterCount: Int { text.count }

    /// The runs of a paragraph or quote; code has none.
    public var runs: [Run] {
        switch self {
        case .paragraph(let runs), .quote(let runs): runs
        case .code: []
        }
    }
}

extension RichText.Block: Codable {
    private enum CodingKeys: String, CodingKey { case type, runs, text, language }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "paragraph": self = .paragraph(try container.decode([Run].self, forKey: .runs))
        case "quote": self = .quote(try container.decode([Run].self, forKey: .runs))
        case "code":
            self = .code(
                try container.decode(String.self, forKey: .text),
                language: try container.decodeIfPresent(String.self, forKey: .language)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown block type \(other)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .paragraph(let runs):
            try container.encode("paragraph", forKey: .type)
            try container.encode(runs, forKey: .runs)
        case .quote(let runs):
            try container.encode("quote", forKey: .type)
            try container.encode(runs, forKey: .runs)
        case .code(let text, let language):
            try container.encode("code", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(language, forKey: .language)
        }
    }
}

extension RichText: Codable {
    private enum CodingKeys: String, CodingKey { case blocks }

    /// Decodes and brings the value to normal form, so that a document written by another
    /// program, or by an older version, cannot break the invariants the operations rely on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(blocks: try container.decode([Block].self, forKey: .blocks))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blocks, forKey: .blocks)
    }
}
