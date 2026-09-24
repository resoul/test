import Foundation
import Testing

@testable import TrellisCore

// CSS Flexbox conformance (v22/docs/06-flexbox-conformance.md). Every case in
// Conformance/CSSFlexbox/fixtures/flexbox.json was rendered by real Chromium; this test lays
// the same tree out with `FlexboxEngine` and compares every node's frame.
//
// A case ends in one of three outcomes: `pass`, `fail` (a frame differs), or `unsupported`
// (the case uses CSS the engine cannot express at all — `margin: auto`, `order`, …). The
// known outcome of every case is recorded in Conformance/CSSFlexbox/expectations/
// trellis.json, so this test fails on any change in either direction: a regression, or a
// case that started passing and needs its expectation updated. Record a new baseline with
//
//     TRELLIS_CSS_RECORD=1 swift test --filter cssFlexboxConformance
//
// which rewrites the expectations and Conformance/CSSFlexbox/reports/trellis.md.

private let conformanceTolerance = 0.05

private struct CSSFixture: Decodable {
    let browser: String
    let cases: [CSSCase]
}

private struct CSSCase: Decodable {
    let name: String
    let group: String
    let root: CSSNode
    let expected: [CSSFrame]
}

private struct CSSFrame: Decodable {
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

private enum CSSOutcome: Equatable {
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

/// A CSS feature the engine has no way to express. Distinct from a wrong frame: the case is
/// not run, and the report lists it as a gap in the style vocabulary rather than a math bug.
private struct CSSUnsupported: Error {
    let reason: String
}

// MARK: - Style translation

/// Physical CSS edges (`[top, right, bottom, left]` or one value) as plain numbers.
private func cssEdges(_ value: CSSValue, property: String) throws -> [Double] {
    let parts: [CSSValue]
    switch value {
    case .number, .string: parts = [value, value, value, value]
    case let .list(values): parts = values
    }
    guard parts.count == 4 else {
        throw CSSUnsupported(reason: "\(property): \(value)")
    }

    return try parts.map { part in
        guard case let .number(number) = part else {
            throw CSSUnsupported(reason: "\(property): \(part)")
        }

        return number
    }
}

private func cssNumber(_ value: CSSValue, property: String) throws -> Double {
    guard case let .number(number) = value else {
        throw CSSUnsupported(reason: "\(property): \(value)")
    }

    return number
}

private func cssSize(_ value: CSSValue, property: String) throws -> SizeValue {
    switch value {
    case let .number(number):
        return .points(number)
    case .string("auto"):
        return .auto
    case let .string(string) where string.hasSuffix("%"):
        guard let percent = Double(string.dropLast()) else {
            throw CSSUnsupported(reason: "\(property): \(string)")
        }

        return .fraction(percent / 100)
    default:
        throw CSSUnsupported(reason: "\(property): \(value)")
    }
}

private func cssKeyword<Value>(
    _ value: CSSValue,
    property: String,
    _ table: [String: Value]
) throws -> Value {
    guard case let .string(keyword) = value, let mapped = table[keyword] else {
        throw CSSUnsupported(reason: "\(property): \(value)")
    }

    return mapped
}

private let cssJustify: [String: JustifyContent] = [
    "flex-start": .start,
    "flex-end": .end,
    "center": .center,
    "space-between": .spaceBetween,
    "space-around": .spaceAround,
    "space-evenly": .spaceEvenly,
]

private let cssAlignContent: [String: AlignContent] = [
    "flex-start": .start,
    "flex-end": .end,
    "center": .center,
    "stretch": .stretch,
    "space-between": .spaceBetween,
    "space-around": .spaceAround,
    "space-evenly": .spaceEvenly,
]

private let cssAlignItems: [String: AlignItems] = [
    "stretch": .stretch,
    "flex-start": .start,
    "flex-end": .end,
    "center": .center,
    "baseline": .baseline,
]

private let cssAlignSelf: [String: AlignSelf] = [
    "auto": .auto,
    "stretch": .stretch,
    "flex-start": .start,
    "flex-end": .end,
    "center": .center,
    "baseline": .baseline,
]

private let cssDirection: [String: FlexDirection] = [
    "row": .row,
    "column": .column,
    "row-reverse": .rowReverse,
    "column-reverse": .columnReverse,
]

private let cssWrap: [String: FlexWrap] = [
    "nowrap": .noWrap,
    "wrap": .wrap,
    "wrap-reverse": .wrapReverse,
]

/// Builds the engine input for one CSS node. Physical CSS edges (`left`/`right`) become
/// logical ones for the node's inherited `direction`, and CSS `row-gap`/`column-gap` become the
/// engine's main-axis `gap` and cross-axis `crossGap` for its `flex-direction`.
private func cssSnapshot(
    _ node: CSSNode,
    direction inherited: LayoutDirection,
    nextID: inout UInt64
) throws -> LayoutInputSnapshot {
    let identity = NodeID(rawValue: nextID)
    nextID += 1
    var direction = inherited
    if let value = node.style["direction"] {
        direction = try cssKeyword(
            value,
            property: "direction",
            ["ltr": LayoutDirection.leftToRight, "rtl": .rightToLeft]
        )
    }

    let isRTL = direction == .rightToLeft
    var style = LayoutStyle()
    var content = LayoutContentMetrics()
    var rowGap = 0.0
    var columnGap = 0.0
    var physicalOffsets: [String: Double] = [:]

    for (property, value) in node.style {
        switch property {
        case "direction":
            break
        case "flexDirection":
            style.flexDirection = try cssKeyword(value, property: property, cssDirection)
        case "flexWrap":
            style.flexWrap = try cssKeyword(value, property: property, cssWrap)
        case "justifyContent":
            style.justifyContent = try cssKeyword(value, property: property, cssJustify)
        case "alignItems":
            style.alignItems = try cssKeyword(value, property: property, cssAlignItems)
        case "alignSelf":
            style.alignSelf = try cssKeyword(value, property: property, cssAlignSelf)
        case "alignContent":
            style.alignContent = try cssKeyword(value, property: property, cssAlignContent)
        case "flexGrow":
            style.flexGrow = try cssNumber(value, property: property)
        case "flexShrink":
            style.flexShrink = try cssNumber(value, property: property)
        case "flexBasis":
            style.flexBasis = try cssSize(value, property: property)
        case "width":
            style.width = try cssSize(value, property: property)
        case "height":
            style.height = try cssSize(value, property: property)
        case "minWidth":
            style.minWidth = try cssSize(value, property: property)
        case "maxWidth":
            style.maxWidth = try cssSize(value, property: property)
        case "minHeight":
            style.minHeight = try cssSize(value, property: property)
        case "maxHeight":
            style.maxHeight = try cssSize(value, property: property)
        case "aspectRatio":
            style.aspectRatio = try cssNumber(value, property: property)
        case "rowGap":
            rowGap = try cssNumber(value, property: property)
        case "columnGap":
            columnGap = try cssNumber(value, property: property)
        case "padding", "margin":
            let edges = try cssEdges(value, property: property)
            let insets = DirectionalEdgeInsets(
                top: edges[0],
                leading: isRTL ? edges[1] : edges[3],
                bottom: edges[2],
                trailing: isRTL ? edges[3] : edges[1]
            )
            if property == "padding" {
                style.padding = insets
            } else {
                style.margin = insets
            }
        case "position":
            style.positionType = try cssKeyword(
                value,
                property: property,
                ["relative": PositionType.relative, "absolute": .absolute]
            )
        case "top", "right", "bottom", "left":
            physicalOffsets[property] = try cssNumber(value, property: property)
        case "content":
            guard case let .list(size) = value, size.count == 2,
                case let .number(width) = size[0], case let .number(height) = size[1]
            else {
                throw CSSUnsupported(reason: "content: \(value)")
            }

            content = LayoutContentMetrics(intrinsic: MeasuredSize(width: width, height: height))
        default:
            throw CSSUnsupported(reason: "\(property): \(value)")
        }
    }

    let isHorizontal = style.flexDirection == .row || style.flexDirection == .rowReverse
    style.gap = isHorizontal ? columnGap : rowGap
    style.crossGap = isHorizontal ? rowGap : columnGap
    if !physicalOffsets.isEmpty {
        style.offsets = DirectionalEdgeOffsets(
            top: physicalOffsets["top"],
            leading: isRTL ? physicalOffsets["right"] : physicalOffsets["left"],
            bottom: physicalOffsets["bottom"],
            trailing: isRTL ? physicalOffsets["left"] : physicalOffsets["right"]
        )
    }

    var children: [LayoutInputSnapshot] = []
    for child in node.children {
        children.append(try cssSnapshot(child, direction: direction, nextID: &nextID))
    }

    return LayoutInputSnapshot(
        identity: identity,
        style: style,
        content: content,
        children: children,
        direction: direction
    )
}

// MARK: - Running a case

private func cssFrameText(x: Double, y: Double, width: Double, height: Double) -> String {
    func format(_ value: Double) -> String { String(format: "%.2f", value) }
    return "(\(format(x)), \(format(y)), \(format(width))×\(format(height)))"
}

/// Lays the case out the way a host does: the root gets Chromium's root frame as its bounds,
/// and every other frame is the engine's own. Node ids follow the generator's pre-order
/// numbering: `n0` is the root, `nK` is the K-th node visited.
private func runCSSCase(_ testCase: CSSCase) -> CSSOutcome {
    guard let rootFrame = testCase.expected.first(where: { $0.id == "n0" }) else {
        return .fail("fixture has no root frame")
    }

    var nextID: UInt64 = 1
    let input: LayoutInputSnapshot
    do {
        input = try cssSnapshot(testCase.root, direction: .leftToRight, nextID: &nextID)
    } catch let unsupported as CSSUnsupported {
        return .unsupported(unsupported.reason)
    } catch {
        return .fail("snapshot: \(error)")
    }

    let result: LayoutResult
    do {
        result = try FlexboxEngine.layoutContainer(
            input: input,
            frame: LayoutFrame(width: rootFrame.width, height: rootFrame.height),
            roundingPolicy: PixelRoundingPolicy(scale: 64)
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

        let chromium = cssFrameText(
            x: expected.x,
            y: expected.y,
            width: expected.width,
            height: expected.height
        )
        guard let placement = result.placement(for: NodeID(rawValue: index + 1)) else {
            mismatches.append("\(expected.id): chromium \(chromium), engine none")
            continue
        }

        let frame = placement.frame
        let differs = [
            (frame.origin.x, expected.x),
            (frame.origin.y, expected.y),
            (frame.width, expected.width),
            (frame.height, expected.height),
        ].contains { abs($0.0 - $0.1) > conformanceTolerance }
        if differs {
            let engine = cssFrameText(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
            mismatches.append("\(expected.id): chromium \(chromium), engine \(engine)")
        }
    }

    return mismatches.isEmpty ? .pass : .fail(mismatches.joined(separator: "; "))
}

// MARK: - Baseline

private let conformanceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Layout
    .deletingLastPathComponent()  // TrellisCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("Conformance/CSSFlexbox")

private func cssReport(
    fixture: CSSFixture,
    outcomes: [(name: String, outcome: CSSOutcome)]
) -> String {
    let total = outcomes.count
    let passed = outcomes.filter { $0.outcome == .pass }.count
    let unsupported = outcomes.filter { $0.outcome.name == "unsupported" }.count
    let failed = total - passed - unsupported
    var lines = [
        "# FlexboxEngine против CSS",
        "",
        "Эталон: \(fixture.browser). Допуск: \(conformanceTolerance) pt.",
        "Сгенерировано `TRELLIS_CSS_RECORD=1 swift test --filter cssFlexboxConformance`.",
        "",
        "| Итог | Кейсов |",
        "|---|---|",
        "| pass | \(passed) из \(total) |",
        "| fail | \(failed) |",
        "| unsupported | \(unsupported) |",
        "",
        "## По группам",
        "",
        "| Группа | pass | fail | unsupported |",
        "|---|---|---|---|",
    ]
    let groups = Dictionary(grouping: fixture.cases, by: \.group).keys.sorted()
    for group in groups {
        let inGroup = outcomes.filter { $0.name.hasPrefix("\(group)/") }
        let count = { (name: String) in inGroup.filter { $0.outcome.name == name }.count }
        lines.append("| \(group) | \(count("pass")) | \(count("fail")) | \(count("unsupported")) |")
    }
    lines += ["", "## Расхождения", ""]
    for entry in outcomes {
        if let detail = entry.outcome.detail {
            lines.append("- `\(entry.name)` — \(entry.outcome.name): \(detail)")
        }
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

@Test
func cssFlexboxConformance() throws {
    let fixtureURL = conformanceRoot.appendingPathComponent("fixtures/flexbox.json")
    let expectationsURL = conformanceRoot.appendingPathComponent("expectations/trellis.json")
    let reportURL = conformanceRoot.appendingPathComponent("reports/trellis.md")

    let fixture = try JSONDecoder().decode(CSSFixture.self, from: Data(contentsOf: fixtureURL))
    let outcomes = fixture.cases.map { (name: $0.name, outcome: runCSSCase($0)) }
    #expect(!outcomes.isEmpty)

    if ProcessInfo.processInfo.environment["TRELLIS_CSS_RECORD"] == "1" {
        let pairs = outcomes.map { ($0.name, $0.outcome.name) }
        let expectations = Dictionary(uniqueKeysWithValues: pairs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manager = FileManager.default
        try manager.createDirectory(
            at: expectationsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(expectations).write(to: expectationsURL)
        try Data(cssReport(fixture: fixture, outcomes: outcomes).utf8).write(to: reportURL)
        return
    }

    guard let data = try? Data(contentsOf: expectationsURL) else {
        let hint = "TRELLIS_CSS_RECORD=1 swift test --filter cssFlexboxConformance"
        Issue.record("No CSS conformance baseline at \(expectationsURL.path); record: \(hint)")
        return
    }

    let expectations = try JSONDecoder().decode([String: String].self, from: data)
    for entry in outcomes {
        let expected = expectations[entry.name] ?? "missing"
        if expected != entry.outcome.name {
            let detail = entry.outcome.detail ?? ""
            Issue.record("\(entry.name): baseline \(expected), now \(entry.outcome.name) \(detail)")
        }
    }
}
