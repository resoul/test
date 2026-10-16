import Foundation

/// One character of a block with the style it is set in. Editing works on cells and builds
/// the block again from them, which is what keeps runs coalesced and their borders between
/// characters.
struct Cell: Hashable {
    var character: Character
    var attributes: Attributes
}

/// A scalar and the style of the run it came from.
typealias StyledScalar = (scalar: Unicode.Scalar, attributes: Attributes)

/// The content of a block as characters, whatever its kind.
struct Body {
    var kind: RichText.Kind
    var cells: [Cell]

    /// Builds a body from scalars with their styles: line breaks become `"\n"`, and the scalars
    /// are cut into characters as `String` does, each character taking the style of its first
    /// scalar — this is what keeps a border of two runs from falling inside a character.
    init(kind: RichText.Kind, scalars source: [StyledScalar]) {
        var scalars: [StyledScalar] = []
        scalars.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let (scalar, attributes) = source[index]
            if scalar == "\r" {
                if index + 1 < source.count, source[index + 1].scalar == "\n" {
                    // "\r\n": the "\n" that follows stands for both.
                    index += 1
                    continue
                }
                scalars.append(("\n", attributes))
            } else {
                scalars.append((scalar, attributes))
            }
            index += 1
        }

        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars.map(\.scalar))
        var cells: [Cell] = []
        var scalarIndex = 0
        for character in String(text) {
            var attributes = scalars[scalarIndex].attributes
            attributes.marks.formIntersection(.all)
            cells.append(Cell(character: character, attributes: attributes))
            scalarIndex += character.unicodeScalars.count
        }

        var kind = kind
        if case .code(let language) = kind {
            kind = .code(language: language?.isEmpty == true ? nil : language)
            // Code is plain text.
            for index in cells.indices { cells[index].attributes = .plain }
        }
        self.kind = kind
        self.cells = cells
    }

    /// Builds a body from pieces of text, each in one style.
    init(kind: RichText.Kind, pieces: [(String, Attributes)]) {
        self.init(
            kind: kind,
            scalars: pieces.flatMap { text, attributes in
                text.unicodeScalars.map { ($0, attributes) }
            }
        )
    }

    /// The cells as scalars, for building a body again after an edit.
    var scalars: [StyledScalar] {
        cells.flatMap { cell in cell.character.unicodeScalars.map { ($0, cell.attributes) } }
    }

    /// The scalars of the first `count` cells: where the text is cut in scalars.
    func scalarCount(ofFirst count: Int) -> Int {
        cells.prefix(count).reduce(0) { $0 + $1.character.unicodeScalars.count }
    }

    /// The number of characters of this body that begin before the scalar `boundary`. After an
    /// edit, characters can join or split, so a place is kept as a scalar boundary and turned
    /// back into a character offset here; when the boundary falls inside a character, the
    /// place is after that character, never inside it.
    func characterCount(beforeScalar boundary: Int) -> Int {
        var start = 0
        var count = 0
        for cell in cells {
            if start >= boundary { break }
            count += 1
            start += cell.character.unicodeScalars.count
        }
        return count
    }

    /// The style new text gets when it is typed at `offset`: the marks of the character before
    /// (the first one at the start of a block), and the link only when the characters on both
    /// sides are in the same link, so that typing at the end of a link does not extend it.
    func typingAttributes(at offset: Int) -> Attributes {
        let offset = min(max(offset, 0), cells.count)
        let before = offset > 0 ? cells[offset - 1].attributes : nil
        let after = offset < cells.count ? cells[offset].attributes : nil
        let marks = (before ?? after)?.marks ?? []
        var link: URL?
        if let before, let after, before.link == after.link { link = before.link }
        return Attributes(marks: marks, link: link)
    }

    /// The block this body makes.
    var block: RichText.Block {
        switch kind {
        case .code(let language):
            return .code(String(cells.map(\.character)), language: language)
        case .paragraph, .quote:
            var runs: [Run] = []
            for cell in cells {
                if let last = runs.last,
                    last.marks == cell.attributes.marks,
                    last.link == cell.attributes.link
                {
                    runs[runs.count - 1].text.append(cell.character)
                } else {
                    runs.append(
                        Run(
                            String(cell.character),
                            marks: cell.attributes.marks,
                            link: cell.attributes.link
                        )
                    )
                }
            }
            return kind == .quote ? .quote(runs) : .paragraph(runs)
        }
    }
}

extension RichText.Block {
    /// The content of the block as cells.
    var body: Body {
        switch self {
        case .paragraph(let runs):
            Body(
                kind: .paragraph,
                pieces: runs.map { ($0.text, Attributes(marks: $0.marks, link: $0.link)) }
            )
        case .quote(let runs):
            Body(
                kind: .quote,
                pieces: runs.map { ($0.text, Attributes(marks: $0.marks, link: $0.link)) }
            )
        case .code(let text, let language):
            Body(kind: .code(language: language), pieces: [(text, .plain)])
        }
    }

    /// The block in normal form.
    func normalized() -> RichText.Block {
        body.block
    }
}
