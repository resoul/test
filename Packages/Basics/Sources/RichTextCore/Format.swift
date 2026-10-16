import Foundation

/// A change of style a person asks for from a menu, a keyboard shortcut or a toolbar: one of
/// the marks, a link, or the kind of the block. It is the same list on every platform; what
/// each does to a `RichText` is here, and a text view only says which part of its text is
/// selected.
public enum RichFormat: CaseIterable, Sendable, Hashable {
    /// Bold text.
    case bold
    /// Italic text.
    case italic
    /// Text in a monospaced font, as code inside a line.
    case monospace
    /// Text struck through.
    case strikethrough
    /// Underlined text.
    case underline
    /// Makes the selection a link, or takes the link off it; the address comes with the call.
    case link
    /// Makes the blocks of the selection quotations, or paragraphs again.
    case quote
    /// Makes the blocks of the selection code, or paragraphs again.
    case code

    /// The mark the format toggles, or `nil` for a link and the kinds of block.
    public var mark: Marks? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .monospace: .mono
        case .strikethrough: .strike
        case .underline: .underline
        case .link, .quote, .code: nil
        }
    }

    /// The kind of block the format toggles, or `nil` for a mark and a link.
    public var kind: RichText.Kind? {
        switch self {
        case .quote: .quote
        case .code: .code(language: nil)
        default: nil
        }
    }
}

extension RichFormat {
    /// The address a person typed for a link, as a URL: `nil` when nothing usable was typed —
    /// nothing, or words with spaces. An address with a scheme (`http://…`, `mailto:…`,
    /// `tel:…`) is kept as it is; any other is a web address, and `https://` is put before it.
    public static func linkURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme,
            trimmed.contains("://") || scheme == "mailto" || scheme == "tel"
        {
            return url
        }
        return URL(string: "https://" + trimmed)
    }
}

extension RichText {
    /// Whether `format` can do anything at `range` now. Marks and links need a block that can
    /// carry them — code cannot — and a link needs characters to attach to, so a caret is not
    /// enough; a mark at a caret is what the next typed text gets, which the text view keeps.
    /// The kinds of block always apply.
    public func isAvailable(_ format: RichFormat, in range: RichRange) -> Bool {
        let range = clamped(range)
        if format.kind != nil { return true }

        let blocks = range.start.block...range.end.block
        let markable = blocks.contains { index in
            if case .code = self.blocks[index] { return false }
            return true
        }
        guard markable else { return false }

        return format == .link ? !range.isEmpty : true
    }

    /// How much of `range` `format` is already in effect: `.all` when the format would be
    /// taken off, `.none` when it would be put on, `.some` for a mixed selection, which
    /// `apply(_:in:link:)` puts on. For a caret, a mark is the style typed there, a link is
    /// never on, and a kind is that of the block.
    public func state(ofFormat format: RichFormat, in range: RichRange) -> MarkState {
        let range = clamped(range)
        if let mark = format.mark {
            return state(of: mark, in: range)
        }
        if let kind = format.kind {
            var matching = 0
            var other = 0
            for index in range.start.block...range.end.block {
                if blocks[index].kind.isSameKind(as: kind) { matching += 1 } else { other += 1 }
            }
            switch (matching, other) {
            case (0, _): return .none
            case (_, 0): return .all
            default: return .some
            }
        }
        return link(in: range) != nil ? .all : .none
    }

    /// Applies `format` to `range`. A mark is toggled as `toggle(_:in:)` does; a kind of block
    /// is put on every block the range touches, or taken off them — made paragraphs — when
    /// they all have it already, and a block that already has the kind keeps it as it is, the
    /// language of code included. A link becomes `link` on the range; with `nil` the range's
    /// links are taken off. A format that is not available (`isAvailable(_:in:)`) does
    /// nothing.
    public mutating func apply(_ format: RichFormat, in range: RichRange, link: URL? = nil) {
        let range = clamped(range)
        guard isAvailable(format, in: range) else { return }

        if let mark = format.mark {
            toggle(mark, in: range)
        } else if let kind = format.kind {
            let target: Kind = state(ofFormat: format, in: range) == .all ? .paragraph : kind
            for index in range.start.block...range.end.block
            where !blocks[index].kind.isSameKind(as: target) {
                let start = RichPosition(block: index, offset: 0)
                setKind(target, for: RichRange(at: start))
            }
        } else {
            setLink(link, in: range)
        }
    }
}

extension RichText.Kind {
    /// Whether both are paragraphs, both quotes, or both code, whatever the language of the
    /// code.
    fileprivate func isSameKind(as other: RichText.Kind) -> Bool {
        switch (self, other) {
        case (.paragraph, .paragraph), (.quote, .quote), (.code, .code): true
        default: false
        }
    }
}
