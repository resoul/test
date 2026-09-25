import Foundation
import Testing

@testable import LayoutCore

// Compares FlexboxEngine with CSS Flexbox as rendered by Chromium. Every case in
// Conformance/CSSFlexbox/fixtures/ (hand-written and seeded random trees, with and without text) is a
// tree with the frame Chromium gave each node; the test lays out the same tree and compares every frame within `tolerance`.
//
// The known outcome of every case (pass / fail / unsupported) is stored in
// Conformance/CSSFlexbox/expectations/engine.json, and any change in either direction fails the
// test. Record a new baseline, together with a readable report next to it, with
//
//     CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance

private let tolerance = 0.05

private struct Fixture: Decodable {
    let browser: String
    let cases: [Case]
}

private struct Case: Decodable {
    let name: String
    let group: String
    let root: CSSNode
    let expected: [Frame]
}

private struct Frame: Decodable {
    let id: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct CSSNode: Decodable {
    let style: [String: CSSValue]
    let children: [CSSNode]
}

private enum CSSValue: Decodable, CustomStringConvertible {
    case number(Double)
    case string(String)
    case list([CSSValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .list(try container.decode([CSSValue].self))
        }
    }

    var description: String {
        switch self {
        case let .number(value): "\(value)"
        case let .string(value): value
        case let .list(values): "[\(values.map(\.description).joined(separator: ", "))]"
        }
    }
}

private enum Outcome: Equatable {
    case pass
    case fail(String)
    case unsupported(String)

    var name: String {
        switch self {
        case .pass: "pass"
        case .fail: "fail"
        case .unsupported: "unsupported"
        }
    }

    var detail: String? {
        switch self {
        case .pass: nil
        case let .fail(detail), let .unsupported(detail): detail
        }
    }
}

private struct Unsupported: Error {
    let reason: String
}

// MARK: - CSS → FlexStyle

private func number(_ value: CSSValue, _ property: String) throws -> Double {
    guard case let .number(number) = value else {
        throw Unsupported(reason: "\(property): \(value)")
    }

    return number
}

private func dimension(_ value: CSSValue, _ property: String) throws -> Length {
    switch value {
    case let .number(number):
        return .points(number)
    case .string("auto"):
        return .auto
    case let .string(string) where string.hasSuffix("%"):
        guard let percent = Double(string.dropLast()) else {
            throw Unsupported(reason: "\(property): \(string)")
        }

        return .fraction(percent / 100)
    default:
        throw Unsupported(reason: "\(property): \(value)")
    }
}

/// CSS shorthand order: `[top, right, bottom, left]` or one value for all four.
private func physicalEdges(_ value: CSSValue, _ property: String) -> [CSSValue] {
    if case let .list(values) = value, values.count == 4 { return values }
    return [value, value, value, value]
}

private func margin(_ value: CSSValue, _ property: String) throws -> Margin {
    switch value {
    case let .number(number): return .points(number)
    case .string("auto"): return .auto
    default: throw Unsupported(reason: "\(property): \(value)")
    }
}

private func keyword<Value>(_ value: CSSValue, _ property: String, _ table: [String: Value]) throws
    -> Value
{
    guard case let .string(word) = value, let mapped = table[word] else {
        throw Unsupported(reason: "\(property): \(value)")
    }

    return mapped
}

/// Logical edges for a node whose inline direction is `rtl` or not, from physical CSS edges.
private func logical<Value>(_ physical: [Value], rtl: Bool) -> Edges<Value> {
    Edges(
        top: physical[0],
        leading: rtl ? physical[1] : physical[3],
        bottom: physical[2],
        trailing: rtl ? physical[3] : physical[1]
    )
}

private func makeNode(
    _ css: CSSNode,
    direction inherited: LayoutDirection,
    nextID: inout UInt64
) throws -> LayoutNode {
    let id = LayoutID(nextID)
    nextID += 1
    var direction = inherited
    if let value = css.style["direction"] {
        direction = try keyword(
            value,
            "direction",
            ["ltr": LayoutDirection.leftToRight, "rtl": .rightToLeft]
        )
    }

    let rtl = direction == .rightToLeft
    var style = FlexStyle()
    var content: LeafContent?
    var physicalInsets: [String: Double] = [:]

    for (property, value) in css.style {
        switch property {
        case "direction":
            break
        case "flexDirection":
            style.direction = try keyword(
                value,
                property,
                [
                    "row": FlexDirection.row, "column": .column, "row-reverse": .rowReverse,
                    "column-reverse": .columnReverse,
                ]
            )
        case "flexWrap":
            style.wrap = try keyword(
                value,
                property,
                ["nowrap": FlexWrap.noWrap, "wrap": .wrap, "wrap-reverse": .wrapReverse]
            )
        case "justifyContent":
            style.justifyContent = try keyword(
                value,
                property,
                [
                    "flex-start": JustifyContent.start, "flex-end": .end, "center": .center,
                    "space-between": .spaceBetween, "space-around": .spaceAround,
                    "space-evenly": .spaceEvenly,
                ]
            )
        case "alignItems":
            style.alignItems = try keyword(
                value,
                property,
                [
                    "stretch": AlignItems.stretch, "flex-start": .start, "flex-end": .end,
                    "center": .center, "baseline": .baseline,
                ]
            )
        case "alignSelf":
            style.alignSelf = try keyword(
                value,
                property,
                [
                    "auto": AlignSelf.auto, "stretch": .stretch, "flex-start": .start,
                    "flex-end": .end,
                    "center": .center, "baseline": .baseline,
                ]
            )
        case "alignContent":
            style.alignContent = try keyword(
                value,
                property,
                [
                    "stretch": AlignContent.stretch, "flex-start": .start, "flex-end": .end,
                    "center": .center,
                    "space-between": .spaceBetween, "space-around": .spaceAround,
                    "space-evenly": .spaceEvenly,
                ]
            )
        case "flexGrow": style.grow = try number(value, property)
        case "flexShrink": style.shrink = try number(value, property)
        case "flexBasis": style.basis = try dimension(value, property)
        case "width": style.width = try dimension(value, property)
        case "height": style.height = try dimension(value, property)
        case "minWidth": style.minWidth = try dimension(value, property)
        case "maxWidth": style.maxWidth = try dimension(value, property)
        case "minHeight": style.minHeight = try dimension(value, property)
        case "maxHeight": style.maxHeight = try dimension(value, property)
        case "aspectRatio": style.aspectRatio = try number(value, property)
        case "rowGap": style.rowGap = try number(value, property)
        case "columnGap": style.columnGap = try number(value, property)
        case "order": style.order = Int(try number(value, property))
        case "padding":
            style.padding = logical(
                try physicalEdges(value, property).map { try number($0, property) },
                rtl: rtl
            )
        case "margin":
            style.margin = logical(
                try physicalEdges(value, property).map { try margin($0, property) },
                rtl: rtl
            )
        case "position":
            style.position = try keyword(
                value,
                property,
                ["relative": Position.relative, "absolute": .absolute]
            )
        case "top", "right", "bottom", "left":
            physicalInsets[property] = try number(value, property)
        case "content":
            guard case let .list(size) = value, size.count == 2 else {
                throw Unsupported(reason: "content: \(value)")
            }

            content = .size(
                width: try number(size[0], property),
                height: try number(size[1], property)
            )
        case "text":
            guard case let .list(values) = value, let first = values.first else {
                throw Unsupported(reason: "text: \(value)")
            }

            content = .measured(
                WordsMeasurer(
                    lineHeight: try number(first, property),
                    words: try values.dropFirst().map { try number($0, property) }
                )
            )
        default:
            throw Unsupported(reason: "\(property): \(value)")
        }
    }

    style.insets = logical(
        [
            physicalInsets["top"], physicalInsets["right"], physicalInsets["bottom"],
            physicalInsets["left"],
        ],
        rtl: rtl
    )

    var children: [LayoutNode] = []
    for child in css.children {
        children.append(try makeNode(child, direction: direction, nextID: &nextID))
    }

    return LayoutNode(
        id: id,
        style: style,
        content: content,
        direction: direction,
        children: children
    )
}

/// Text as the fixtures model it: words of fixed widths and one line height, wrapped greedily
/// — exactly how a browser wraps a line of equal-height inline blocks.
private struct WordsMeasurer: ContentMeasurer {
    let lineHeight: Double
    let words: [Double]

    func minContentWidth() -> Double { words.max() ?? 0 }

    func maxContentWidth() -> Double { words.reduce(0, +) }

    /// Words sit on the baseline, so the first baseline is the bottom of the first line.
    func firstBaseline(forWidth width: Double) -> Double? { words.isEmpty ? nil : lineHeight }

    func height(forWidth width: Double) -> Double {
        guard !words.isEmpty else { return 0 }

        var lines = 1
        var used = 0.0
        for word in words {
            if used > 0 && used + word > width + 1e-9 {
                lines += 1
                used = word
            } else {
                used += word
            }
        }

        return Double(lines) * lineHeight
    }
}

// MARK: - Running a case

private func format(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> String {
    func text(_ value: Double) -> String { String(format: "%.2f", value) }
    return "(\(text(x)), \(text(y)), \(text(width))×\(text(height)))"
}

/// Node ids follow the generator's pre-order numbering: `n0` is the root, `nK` the K-th node.
private func run(_ testCase: Case) -> Outcome {
    guard let rootFrame = testCase.expected.first(where: { $0.id == "n0" }) else {
        return .fail("fixture has no root frame")
    }

    var nextID: UInt64 = 0
    let root: LayoutNode
    do {
        root = try makeNode(testCase.root, direction: .leftToRight, nextID: &nextID)
    } catch let unsupported as Unsupported {
        return .unsupported(unsupported.reason)
    } catch {
        return .fail("input: \(error)")
    }

    let result: LayoutResult
    do {
        result = try FlexboxEngine.layout(
            root,
            size: LayoutSize(width: rootFrame.width, height: rootFrame.height)
        )
    } catch {
        return .fail("engine threw \(error)")
    }

    var mismatches: [String] = []
    for expected in testCase.expected {
        guard let index = UInt64(expected.id.dropFirst()) else {
            mismatches.append("\(expected.id): bad id")
            continue
        }

        let chromium = format(expected.x, expected.y, expected.width, expected.height)
        guard let frame = result.frame(for: LayoutID(index)) else {
            mismatches.append("\(expected.id): chromium \(chromium), engine none")
            continue
        }

        let differs = [
            (frame.origin.x, expected.x),
            (frame.origin.y, expected.y),
            (frame.size.width, expected.width),
            (frame.size.height, expected.height),
        ].contains { abs($0.0 - $0.1) > tolerance }
        if differs {
            let engine = format(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)
            mismatches.append("\(expected.id): chromium \(chromium), engine \(engine)")
        }
    }

    return mismatches.isEmpty ? .pass : .fail(mismatches.joined(separator: "; "))
}

// MARK: - Baseline

private let conformanceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // LayoutCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // package root
    .appendingPathComponent("Conformance/CSSFlexbox")

private func report(_ fixture: Fixture, _ outcomes: [(name: String, outcome: Outcome)]) -> String {
    let count = { (name: String) in outcomes.filter { $0.outcome.name == name }.count }
    var lines = [
        "# FlexboxEngine против CSS",
        "",
        "Эталон: \(fixture.browser). Допуск: \(tolerance) pt.",
        "Сгенерировано `CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance` в корне пакета.",
        "",
        "| Итог | Кейсов |",
        "|---|---|",
        "| pass | \(count("pass")) из \(outcomes.count) |",
        "| fail | \(count("fail")) |",
        "| unsupported | \(count("unsupported")) |",
        "",
        "## По группам",
        "",
        "| Группа | pass | fail | unsupported |",
        "|---|---|---|---|",
    ]
    for group in Set(fixture.cases.map(\.group)).sorted() {
        let inGroup = outcomes.filter { $0.name.hasPrefix("\(group)/") }
        let inGroupCount = { (name: String) in inGroup.filter { $0.outcome.name == name }.count }
        lines.append(
            "| \(group) | \(inGroupCount("pass")) | \(inGroupCount("fail")) | \(inGroupCount("unsupported")) |"
        )
    }
    lines += ["", "## Расхождения", ""]
    let failures = outcomes.compactMap { entry in
        entry.outcome.detail.map { "- `\(entry.name)` — \(entry.outcome.name): \($0)" }
    }
    lines += failures.isEmpty ? ["Нет."] : failures
    lines.append("")
    return lines.joined(separator: "\n")
}

/// Lays out every case of the fixture at `CSS_CONFORMANCE_LAB` and writes each outcome next to
/// it (`<file>.engine.json`): a way to check trees reduced from a failing case.
@Test
func cssFlexboxLab() throws {
    guard let path = ProcessInfo.processInfo.environment["CSS_CONFORMANCE_LAB"] else { return }

    let url = URL(fileURLWithPath: path)
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    let outcomes = Dictionary(
        uniqueKeysWithValues: fixture.cases.map { ($0.name, run($0).detail ?? "pass") }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(outcomes).write(to: url.appendingPathExtension("engine.json"))
}

@Test
func cssFlexboxConformance() throws {
    // Hand-written cases, then seeded random trees; both rendered by the same browser.
    let fixtureFiles = [
        "fixtures/flexbox.json",
        "fixtures/random.json",
        "fixtures/text.json",
        "fixtures/random-text.json",
        "fixtures/random-baseline.json",
        "fixtures/reduced.json",
    ]
    let expectationsURL = conformanceRoot.appendingPathComponent("expectations/engine.json")
    let reportURL = conformanceRoot.appendingPathComponent("reports/engine.md")

    let fixtures = try fixtureFiles.map { file in
        try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: conformanceRoot.appendingPathComponent(file))
        )
    }
    // Fixtures can come from different browser versions: the report names each of them.
    let browsers = Set(fixtures.map(\.browser)).sorted().joined(separator: ", ")
    let fixture = Fixture(browser: browsers, cases: fixtures.flatMap(\.cases))
    let outcomes = fixture.cases.map { (name: $0.name, outcome: run($0)) }
    #expect(!outcomes.isEmpty)

    if ProcessInfo.processInfo.environment["CSS_CONFORMANCE_RECORD"] == "1" {
        let expectations = Dictionary(
            uniqueKeysWithValues: outcomes.map { ($0.name, $0.outcome.name) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(expectations).write(to: expectationsURL)
        try Data(report(fixture, outcomes).utf8).write(to: reportURL)
        return
    }

    guard let data = try? Data(contentsOf: expectationsURL) else {
        let hint = "CSS_CONFORMANCE_RECORD=1 swift test --filter cssFlexboxConformance"
        Issue.record("No CSS conformance baseline at \(expectationsURL.path); record: \(hint)")
        return
    }

    let expectations = try JSONDecoder().decode([String: String].self, from: data)
    for entry in outcomes {
        let expected = expectations[entry.name] ?? "missing"
        if expected != entry.outcome.name {
            Issue.record(
                "\(entry.name): baseline \(expected), now \(entry.outcome.name) \(entry.outcome.detail ?? "")"
            )
        }
    }
}
