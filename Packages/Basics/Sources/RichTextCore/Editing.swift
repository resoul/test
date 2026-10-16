import Foundation

/// How much of a range has a mark.
public enum MarkState: Sendable, Hashable {
    /// No character of the range has it.
    case none
    /// Some do, and some do not.
    case some
    /// Every character has it.
    case all
}

extension RichText {
    // MARK: Typing and deleting

    /// The style text typed at `position` gets: the marks of the character before the place, and
    /// the link only when the characters on both sides share it. In code there is none.
    public func typingAttributes(at position: RichPosition) -> Attributes {
        let position = clamped(position)
        return blocks[position.block].body.typingAttributes(at: position.offset)
    }

    /// Inserts `text` at `position` and returns the place after it, for the caret.
    ///
    /// The text has `attributes`, or, when they are `nil`, `typingAttributes(at:)`. It stays in
    /// the block: a `"\n"` in it is a line break, and `splitBlock(at:)` is what makes a new
    /// block. Inserting a combining scalar joins it to the character before it, so the returned
    /// place — which is always between characters — can differ from `position` plus the count
    /// of the inserted characters.
    @discardableResult
    public mutating func insert(
        _ text: String,
        at position: RichPosition,
        attributes: Attributes? = nil
    ) -> RichPosition {
        let position = clamped(position)
        guard !text.isEmpty else { return position }

        let body = blocks[position.block].body
        let typed = attributes ?? body.typingAttributes(at: position.offset)
        let before = body.cells.prefix(position.offset)
        let after = body.cells.dropFirst(position.offset)
        let head = Body(kind: body.kind, pieces: pieces(of: before) + [(text, typed)])
        let whole = Body(
            kind: body.kind,
            pieces: pieces(of: before) + [(text, typed)] + pieces(of: after)
        )
        blocks[position.block] = whole.block
        return RichPosition(
            block: position.block,
            offset: whole.characterCount(beforeScalar: head.scalars.count)
        )
    }

    /// Deletes the text of `range` and returns the place where it was.
    ///
    /// A range across blocks removes the blocks between and joins the rest of the last block to
    /// the first, which keeps its kind: the text that was after the range takes on the first
    /// block's kind, and its marks are lost if that is code.
    @discardableResult
    public mutating func delete(_ range: RichRange) -> RichPosition {
        let range = clamped(range)
        guard !range.isEmpty else { return range.start }

        let first = blocks[range.start.block].body
        let last = blocks[range.end.block].body
        let before = first.cells.prefix(range.start.offset)
        let after = last.cells.dropFirst(range.end.offset)
        let head = Body(kind: first.kind, pieces: pieces(of: before))
        let joined = Body(kind: first.kind, pieces: pieces(of: before) + pieces(of: after))
        replaceBlocks(range.start.block..<(range.end.block + 1), with: [joined.block])
        return RichPosition(
            block: range.start.block,
            offset: joined.characterCount(beforeScalar: head.scalars.count)
        )
    }

    /// What the Backspace key does at `position`, and where the caret goes.
    ///
    /// In the middle of a block it deletes the character before the caret. At the start of a
    /// quote or a code block it makes the block a paragraph and keeps the text. At the start of
    /// a paragraph it joins the paragraph to the block before it, which keeps its kind; at the
    /// start of the text it does nothing.
    @discardableResult
    public mutating func deleteBackward(at position: RichPosition) -> RichPosition {
        let position = clamped(position)
        if position.offset > 0 {
            return delete(
                RichRange(
                    RichPosition(block: position.block, offset: position.offset - 1),
                    position
                )
            )
        }
        if blocks[position.block].kind != .paragraph {
            setKind(.paragraph, for: RichRange(at: position))
            return position
        }
        guard position.block > 0 else { return position }

        let previous = position.block - 1
        return delete(
            RichRange(
                RichPosition(block: previous, offset: blocks[previous].characterCount),
                position
            )
        )
    }

    /// What the Return key does at `position`, and where the caret goes.
    ///
    /// In a paragraph it splits the block in two, each half keeping its styles. In a quote or
    /// code it inserts a line break, so that the block goes on; at the end of the block, on a
    /// line that is empty, it takes that line away and starts a paragraph after the block — the
    /// way out of a quote or code. In an empty quote or code block it makes the block a
    /// paragraph.
    @discardableResult
    public mutating func splitBlock(at position: RichPosition) -> RichPosition {
        let position = clamped(position)
        let body = blocks[position.block].body

        switch body.kind {
        case .paragraph:
            let head = Body(
                kind: .paragraph,
                pieces: pieces(of: body.cells.prefix(position.offset))
            )
            let tail = Body(
                kind: .paragraph,
                pieces: pieces(of: body.cells.dropFirst(position.offset))
            )
            replaceBlocks(position.block..<(position.block + 1), with: [head.block, tail.block])
            return RichPosition(block: position.block + 1, offset: 0)

        case .quote, .code:
            if body.cells.isEmpty {
                setKind(.paragraph, for: RichRange(at: position))
                return position
            }
            let atEnd = position.offset == body.cells.count
            if atEnd, body.cells.last?.character == "\n" {
                let kept = Body(kind: body.kind, pieces: pieces(of: body.cells.dropLast()))
                replaceBlocks(
                    position.block..<(position.block + 1),
                    with: [kept.block, .paragraph([])]
                )
                return RichPosition(block: position.block + 1, offset: 0)
            }
            return insert(
                "\n",
                at: position,
                attributes: body.typingAttributes(at: position.offset)
            )
        }
    }

    // MARK: Styles

    /// How much of `range` has `mark`, over the characters that can be marked — code cannot.
    /// For a caret it is the state of the style typed there.
    public func state(of mark: Marks, in range: RichRange) -> MarkState {
        let range = clamped(range)
        if range.isEmpty {
            if case .code = blocks[range.start.block] { return .none }
            return typingAttributes(at: range.start).marks.isSuperset(of: mark) ? .all : .none
        }

        var with = 0
        var without = 0
        forEachCell(in: range) { _, _, cell in
            if cell.attributes.marks.isSuperset(of: mark) { with += 1 } else { without += 1 }
        }
        switch (with, without) {
        case (0, _): return .none
        case (_, 0): return .all
        default: return .some
        }
    }

    /// The link every markable character of `range` has, or `nil` when the range is empty, has
    /// none, or has different links or characters without one. Code has no links and is left
    /// out.
    public func link(in range: RichRange) -> URL? {
        let range = clamped(range)
        guard !range.isEmpty else { return nil }

        var shared: URL?
        var consistent = true
        var seen = false
        forEachCell(in: range) { _, _, cell in
            guard consistent else { return }

            guard let link = cell.attributes.link, !seen || link == shared else {
                consistent = false
                return
            }
            shared = link
            seen = true
        }
        return consistent ? shared : nil
    }

    /// Toggles `marks` over `range`, each mark on its own: when every markable character of
    /// the range has the mark it is taken off them all; when none has it, or only some do, it
    /// is put on them all. The text and every position stay as they are. Code is not marked,
    /// and a caret marks nothing.
    public mutating func toggle(_ marks: Marks, in range: RichRange) {
        let range = clamped(range)
        for mark in marks.singles {
            guard !range.isEmpty else { return }
            let remove = state(of: mark, in: range) == .all
            modifyCells(in: range) { attributes in
                if remove { attributes.marks.remove(mark) } else { attributes.marks.insert(mark) }
            }
        }
    }

    /// Makes the characters of `range` a link to `url`, or takes links off them when `url` is
    /// `nil`. Code has no links.
    public mutating func setLink(_ url: URL?, in range: RichRange) {
        let range = clamped(range)
        guard !range.isEmpty else { return }
        modifyCells(in: range) { $0.link = url }
    }

    /// Makes every block that `range` touches a block of `kind`, keeping its text. Marks and
    /// links are lost when a block becomes code and are not brought back when it stops being
    /// one.
    public mutating func setKind(_ kind: Kind, for range: RichRange) {
        let range = clamped(range)
        for index in range.start.block...range.end.block {
            blocks[index] = Body(kind: kind, scalars: blocks[index].body.scalars).block
        }
    }

    // MARK: Helpers

    private func pieces<S: Sequence<Cell>>(of cells: S) -> [(String, Attributes)] {
        cells.map { (String($0.character), $0.attributes) }
    }

    /// Calls `body` for each cell of `range` in a block that can be marked: block index, cell
    /// index in the block, and the cell.
    private func forEachCell(in range: RichRange, _ body: (Int, Int, Cell) -> Void) {
        for index in range.start.block...range.end.block {
            if case .code = blocks[index] { continue }
            let cells = blocks[index].body.cells
            let lower = index == range.start.block ? range.start.offset : 0
            let upper = index == range.end.block ? range.end.offset : cells.count
            guard lower < upper else { continue }
            for cell in lower..<upper { body(index, cell, cells[cell]) }
        }
    }

    private mutating func modifyCells(
        in range: RichRange,
        _ change: (inout Attributes) -> Void
    ) {
        for index in range.start.block...range.end.block {
            if case .code = blocks[index] { continue }
            var body = blocks[index].body
            let lower = index == range.start.block ? range.start.offset : 0
            let upper = index == range.end.block ? range.end.offset : body.cells.count
            guard lower < upper else { continue }
            for cell in lower..<upper { change(&body.cells[cell].attributes) }
            blocks[index] = body.block
        }
    }
}
