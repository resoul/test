import Foundation

extension RichText {
    /// Reads `markdown` in the package's dialect: paragraphs, quotes, fenced code, and inside
    /// them bold, italic, strikethrough, monospaced text and links. Anything else is text.
    ///
    /// The reading never fails and never drops a character that is not syntax: text that looks
    /// like an unfinished construct stays as it is. Underline has no Markdown form, so it is
    /// never produced. See the dialect notes in the design documentation for the exact rules.
    public init(markdown: String) {
        self.init(blocks: MarkdownReader(markdown).blocks())
    }

    /// The text written in the package's dialect, blocks separated by a blank line.
    ///
    /// Writing and reading agree for what the dialect can say: paragraphs, quotes and code with
    /// bold, italic, strikethrough, monospaced text and links. What it cannot say is lost, not
    /// turned into something else: underline, empty paragraphs, and the marks of a run that is
    /// only spaces. Use `Codable` to keep the whole value.
    public var markdown: String {
        blocks.compactMap { MarkdownWriter.write($0) }.joined(separator: "\n\n")
    }
}

// MARK: - Reading

private struct MarkdownReader {
    let lines: [String]

    init(_ source: String) {
        let unified =
            source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        lines = unified.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func blocks() -> [RichText.Block] {
        var blocks: [RichText.Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.allSatisfy(\.isWhitespace) {
                index += 1
            } else if let (length, language) = Self.fenceOpening(line) {
                index += 1
                var content: [String] = []
                while index < lines.count, !Self.closesFence(lines[index], length: length) {
                    content.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(content.joined(separator: "\n"), language: language))
            } else if line.hasPrefix(">") {
                var content: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    var rest = lines[index].dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    content.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(MarkdownInline.runs(content.joined(separator: "\n"))))
            } else {
                var paragraph = [line]
                index += 1
                while index < lines.count, Self.continuesParagraph(lines[index]) {
                    paragraph.append(lines[index])
                    index += 1
                }
                blocks.append(.paragraph(MarkdownInline.runs(paragraph.joined(separator: "\n"))))
            }
        }
        return blocks
    }

    private static func continuesParagraph(_ line: String) -> Bool {
        !line.allSatisfy(\.isWhitespace) && !line.hasPrefix(">") && fenceOpening(line) == nil
    }

    /// The number of backticks and the language of a line that opens a fence, or `nil`. A
    /// line whose words hold a backtick is text with a code span in it, not a fence.
    private static func fenceOpening(_ line: String) -> (Int, String?)? {
        let ticks = line.prefix { $0 == "`" }.count
        guard ticks >= 3 else { return nil }

        let info = line.dropFirst(ticks).trimmingCharacters(in: .whitespaces)
        guard !info.contains("`") else { return nil }

        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return (ticks, language)
    }

    private static func closesFence(_ line: String, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == "`" }
    }
}

/// The inline syntax of a block's text.
private struct MarkdownInline {
    let chars: [Character]

    static func runs(_ text: String) -> [Run] {
        let reader = MarkdownInline(chars: Array(text))
        var runs: [Run] = []
        reader.parse(0..<reader.chars.count, marks: [], link: nil, into: &runs)
        return runs
    }

    /// Signs a backslash can be put before to get the sign itself.
    static let escapable: Set<Character> = ["\\", "`", "*", "_", "~", "[", "]", "(", ")", ">"]

    private func parse(_ range: Range<Int>, marks: Marks, link: URL?, into runs: inout [Run]) {
        var pending = ""
        func flush() {
            if !pending.isEmpty { runs.append(Run(pending, marks: marks, link: link)) }
            pending = ""
        }

        var index = range.lowerBound
        while index < range.upperBound {
            let character = chars[index]

            if character == "\\", index + 1 < range.upperBound,
                Self.escapable.contains(chars[index + 1])
            {
                pending.append(chars[index + 1])
                index += 2
            } else if character == "`" {
                let length = run(of: "`", at: index, before: range.upperBound)
                if let close = closingBackticks(
                    length,
                    from: index + length,
                    before: range.upperBound
                ) {
                    flush()
                    let content = Self.strippedCodeSpan(String(chars[(index + length)..<close]))
                    runs.append(Run(content, marks: marks.union(.mono), link: link))
                    index = close + length
                } else {
                    pending.append(String(repeating: "`", count: length))
                    index += length
                }
            } else if character == "[", link == nil,
                let found = linkAt(index, before: range.upperBound)
            {
                flush()
                parse(found.text, marks: marks, link: found.url, into: &runs)
                index = found.end
            } else if let (delimiter, mark) = delimiter(at: index, before: range.upperBound) {
                let length = delimiter.count
                if canOpen(delimiter, at: index, before: range.upperBound),
                    let close = closer(
                        of: delimiter,
                        from: index + length,
                        before: range.upperBound
                    )
                {
                    flush()
                    parse(
                        (index + length)..<close,
                        marks: marks.union(mark),
                        link: link,
                        into: &runs
                    )
                    index = close + length
                } else {
                    pending.append(delimiter)
                    index += length
                }
            } else {
                pending.append(character)
                index += 1
            }
        }
        flush()
    }

    // MARK: Delimiters

    private func delimiter(at index: Int, before end: Int) -> (String, Marks)? {
        let next = index + 1 < end ? chars[index + 1] : nil
        switch chars[index] {
        case "*": return next == "*" ? ("**", .bold) : ("*", .italic)
        case "~": return next == "~" ? ("~~", .strike) : nil
        case "_": return ("_", .italic)
        default: return nil
        }
    }

    private func matches(_ delimiter: String, at index: Int, before end: Int) -> Bool {
        let signs = Array(delimiter)
        guard index + signs.count <= end else { return false }

        return (0..<signs.count).allSatisfy { chars[index + $0] == signs[$0] }
    }

    private func canOpen(_ delimiter: String, at index: Int, before end: Int) -> Bool {
        let after = index + delimiter.count
        guard after < end, !chars[after].isWhitespace else { return false }

        if delimiter == "_", index > 0, chars[index - 1].isLetter || chars[index - 1].isNumber {
            return false
        }
        return true
    }

    /// The place of the delimiter that closes one opened just before `start`, or `nil`. It is
    /// the first one, outside code spans and escapes, after a sign that is not a space.
    private func closer(of delimiter: String, from start: Int, before end: Int) -> Int? {
        let length = delimiter.count
        var index = start
        while index < end {
            let character = chars[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "`" {
                let ticks = run(of: "`", at: index, before: end)
                if let close = closingBackticks(ticks, from: index + ticks, before: end) {
                    index = close + ticks
                } else {
                    index += ticks
                }
                continue
            }
            if delimiter == "*", character == "*", index + 1 < end, chars[index + 1] == "*" {
                // Part of a bold delimiter, not the end of an italic.
                index += 2
                continue
            }
            if matches(delimiter, at: index, before: end), index > start,
                !chars[index - 1].isWhitespace
            {
                let after = index + length
                if delimiter == "_", after < end, chars[after].isLetter || chars[after].isNumber {
                    index += 1
                    continue
                }
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: Code spans

    private func run(of sign: Character, at index: Int, before end: Int) -> Int {
        var length = 0
        while index + length < end, chars[index + length] == sign { length += 1 }
        return length
    }

    private func closingBackticks(_ length: Int, from start: Int, before end: Int) -> Int? {
        var index = start
        while index < end {
            if chars[index] == "`" {
                let ticks = run(of: "`", at: index, before: end)
                if ticks == length { return index }
                index += ticks
            } else {
                index += 1
            }
        }
        return nil
    }

    /// One space from each side comes off when both sides have one and the span is not only
    /// spaces: this is how a span can begin or end with a backtick.
    private static func strippedCodeSpan(_ content: String) -> String {
        guard content.count >= 2, content.first == " ", content.last == " ",
            content.contains(where: { $0 != " " })
        else { return content }

        return String(content.dropFirst().dropLast())
    }

    // MARK: Links

    private func linkAt(_ start: Int, before end: Int) -> (text: Range<Int>, url: URL, end: Int)? {
        // The matching bracket, outside code spans and escapes.
        var depth = 1
        var index = start + 1
        var textEnd: Int?
        while index < end {
            let character = chars[index]
            if character == "\\" {
                index += 2
            } else if character == "`" {
                let ticks = run(of: "`", at: index, before: end)
                index =
                    (closingBackticks(ticks, from: index + ticks, before: end)).map { $0 + ticks }
                    ?? index + ticks
            } else if character == "[" {
                depth += 1
                index += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    textEnd = index
                    break
                }
                index += 1
            } else {
                index += 1
            }
        }
        guard let textEnd, textEnd + 1 < end, chars[textEnd + 1] == "(" else { return nil }

        var destination = ""
        var parentheses = 0
        index = textEnd + 2
        while index < end {
            let character = chars[index]
            if character == "\\", index + 1 < end, Self.escapable.contains(chars[index + 1]) {
                destination.append(chars[index + 1])
                index += 2
            } else if character == ")", parentheses == 0 {
                guard !destination.isEmpty, let url = URL(string: destination) else { return nil }

                return ((start + 1)..<textEnd, url, index + 1)
            } else if character.isWhitespace {
                return nil
            } else {
                if character == "(" { parentheses += 1 }
                if character == ")" { parentheses -= 1 }
                destination.append(character)
                index += 1
            }
        }
        return nil
    }
}

// MARK: - Writing

private enum MarkdownWriterFidelity: CaseIterable {
    case full
    case withoutItalic
    case plain
}

private enum MarkdownWriter {
    /// How much of the block's styling is written. A block is written in full first and read
    /// back; if the reading does not give the same words — a run of stars that two neighbouring
    /// delimiters made ambiguous — the next, safer way is tried, down to the plain words. So
    /// the words survive whatever the marks are; only the marks can be lost.
    /// The block in Markdown, or `nil` when it has nothing to write: an empty or blank
    /// paragraph.
    static func write(_ block: RichText.Block) -> String? {
        switch block {
        case .paragraph(let runs):
            guard !runs.allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) else { return nil }

            return safest(block, runs: runs) { $0 }
        case .quote(let runs):
            return safest(block, runs: runs) { text in
                text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? ">" : "> " + $0 }
                    .joined(separator: "\n")
            }
        case .code(let text, let language):
            let longest = longestRun(of: "`", in: text)
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let info = language.flatMap { language in
                language.contains(where: { $0.isWhitespace || $0 == "`" }) ? nil : language
            }
            return fence + (info ?? "") + "\n" + (text.isEmpty ? "" : text + "\n") + fence
        }
    }

    private static func safest(
        _ block: RichText.Block,
        runs: [Run],
        frame: (String) -> String
    ) -> String {
        let wanted = block.text.filter { !$0.isWhitespace }
        var last = ""
        for fidelity in MarkdownWriterFidelity.allCases {
            let writer = InlineWriter(fidelity)
            writer.write(runs)
            last = frame(writer.output)
            let read = RichText(markdown: last).plainText.filter { !$0.isWhitespace }
            if read == wanted { return last }
        }
        return last
    }

    fileprivate static func longestRun(of sign: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == sign ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

/// Writes the runs of one block: consecutive runs that share a link, and then a mark, sit in
/// one pair of delimiters, so no two delimiters of one kind meet.
private final class InlineWriter {
    private(set) var output = ""
    private let fidelity: MarkdownWriterFidelity

    /// The marks that are delimiters, from the outermost.
    private static let nesting: [Marks] = [.bold, .strike, .italic]

    /// The characters that a backslash keeps from being syntax.
    private static let escaped: Set<Character> = ["\\", "`", "*", "_", "~", "[", "]"]

    init(_ fidelity: MarkdownWriterFidelity) {
        self.fidelity = fidelity
    }

    func write(_ runs: [Run]) {
        links(runs[...], following: nil)
    }

    private var atLineStart: Bool { output.isEmpty || output.last == "\n" }

    private func links(_ runs: ArraySlice<Run>, following: Character?) {
        var index = runs.startIndex
        while index < runs.endIndex {
            var end = index + 1
            let link = fidelity == .plain ? nil : runs[index].link
            while end < runs.endIndex, (fidelity == .plain ? nil : runs[end].link) == link {
                end += 1
            }
            let group = runs[index..<end]
            let next = Self.firstCharacter(runs[end...]) ?? following
            if let link {
                output += "["
                marks(group, from: 0, following: "*")
                output += "]("
                for character in link.absoluteString {
                    if character == "\\" || character == "(" || character == ")" { output += "\\" }
                    output.append(character)
                }
                output += ")"
            } else {
                marks(group, from: 0, following: next)
            }
            index = end
        }
    }

    private static func firstCharacter(_ runs: ArraySlice<Run>) -> Character? {
        runs.lazy.compactMap { $0.text.first }.first
    }

    private func has(_ mark: Marks, _ run: Run) -> Bool {
        switch fidelity {
        case .plain: false
        case .withoutItalic: mark != .italic && run.marks.contains(mark)
        case .full: run.marks.contains(mark)
        }
    }

    private func marks(_ runs: ArraySlice<Run>, from level: Int, following: Character?) {
        guard level < Self.nesting.count else {
            for run in runs { leaf(run) }
            return
        }
        let mark = Self.nesting[level]
        var index = runs.startIndex
        while index < runs.endIndex {
            let marked = has(mark, runs[index])
            var end = index + 1
            while end < runs.endIndex, has(mark, runs[end]) == marked { end += 1 }
            let group = Array(runs[index..<end])
            let next = Self.firstCharacter(runs[end...]) ?? following

            if marked {
                let (lead, core, trail) = Self.trimmed(group)
                if core.isEmpty {
                    // Only spaces: nothing to put a delimiter around.
                    marks(group[...], from: level + 1, following: next)
                } else {
                    output += lead
                    let sign = delimiter(for: mark, following: trail.first ?? next)
                    output += sign
                    marks(core[...], from: level + 1, following: "*")
                    output += sign
                    output += trail
                }
            } else {
                marks(group[...], from: level + 1, following: next)
            }
            index = end
        }
    }

    /// The delimiter of a mark. Italic is `_` unless a letter or digit touches it, which `_`
    /// does not allow; then it is `*`.
    private func delimiter(for mark: Marks, following: Character?) -> String {
        switch mark {
        case .bold: return "**"
        case .strike: return "~~"
        default:
            let before = output.last
            let touchesWord =
                before.map { $0.isLetter || $0.isNumber } == true
                || following.map { $0.isLetter || $0.isNumber } == true
            return touchesWord ? "*" : "_"
        }
    }

    /// The runs without the spaces at their two ends, and those spaces: a delimiter cannot
    /// follow or precede a space, so they go outside. A monospaced run keeps its spaces in
    /// its span.
    private static func trimmed(_ runs: [Run]) -> (String, [Run], String) {
        var core = runs
        var lead = ""
        var trail = ""
        while let first = core.first, !first.marks.contains(.mono) {
            let spaces = first.text.prefix { $0.isWhitespace }
            lead += spaces
            if spaces.count == first.text.count {
                core.removeFirst()
            } else {
                core[0].text = String(first.text.dropFirst(spaces.count))
                break
            }
        }
        while let last = core.last, !last.marks.contains(.mono) {
            let spaces = String(last.text.reversed().prefix { $0.isWhitespace }.reversed())
            trail = spaces + trail
            if spaces.count == last.text.count {
                core.removeLast()
            } else {
                core[core.count - 1].text = String(last.text.dropLast(spaces.count))
                break
            }
        }
        return (lead, core, trail)
    }

    private func leaf(_ run: Run) {
        if run.marks.contains(.mono), fidelity != .plain {
            output += Self.codeSpan(run.text)
            return
        }
        for character in run.text {
            if Self.escaped.contains(character) || (character == ">" && atLineStart) {
                output += "\\"
            }
            output.append(character)
        }
    }

    private static func codeSpan(_ text: String) -> String {
        let fence = String(repeating: "`", count: MarkdownWriter.longestRun(of: "`", in: text) + 1)
        let needsSpaces =
            text.first == "`" || text.last == "`"
            || (text.first == " " && text.last == " " && text.contains { $0 != " " })
        return needsSpaces ? fence + " " + text + " " + fence : fence + text + fence
    }
}
