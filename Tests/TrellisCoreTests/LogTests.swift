import Testing

@testable import TrellisCore

@Test
func test_parseLogAreas_unsetReturnsFallback() {
    let fallback: Set<LogArea> = [.tree, .host]

    #expect(parseLogAreas(nil, fallback: fallback) == fallback)
}

@Test
func test_parseLogAreas_allEnablesEveryArea() {
    #expect(parseLogAreas("all", fallback: []) == Set(LogArea.allCases))
}

@Test
func test_parseLogAreas_offDisablesEveryArea() {
    #expect(parseLogAreas("off", fallback: Set(LogArea.allCases)) == [])
}

@Test
func test_parseLogAreas_commaListSelectsNamedAreas() {
    #expect(parseLogAreas("schedule,commit", fallback: []) == [.schedule, .commit])
}

@Test
func test_parseLogAreas_unknownNamesAreDroppedNotFatal() {
    #expect(parseLogAreas("schedule,not-a-real-area,host", fallback: []) == [.schedule, .host])
}

@Test
func test_parseLogAreas_emptyStringIsAnEmptyListNotFallback() {
    #expect(parseLogAreas("", fallback: Set(LogArea.allCases)) == [])
}

@Test @MainActor
func test_formatLogLine_includesAllFieldsInFixedOrder() {
    let node = NodeIDAllocator.allocate()
    let parent = NodeIDAllocator.allocate()

    let line = formatLogLine(
        area: .schedule,
        event: "request",
        host: 1,
        generation: 41,
        node: node,
        parent: parent,
        details: "frame=390x844"
    )

    #expect(
        line == "[trellis.schedule] request host=1 gen=41 \(node) parent=\(parent) frame=390x844"
    )
}

@Test
func test_formatLogLine_missingCorrelationFieldsPrintAsNone() {
    let line = formatLogLine(
        area: .tree,
        event: "created",
        host: nil,
        generation: nil,
        node: nil,
        parent: nil,
        details: ""
    )

    #expect(line == "[trellis.tree] created host=none gen=none #none parent=#none")
}

@Test @MainActor
func test_formatLogLine_distinguishesParallelHostsAndGenerations() {
    let a = formatLogLine(
        area: .host,
        event: "mount",
        host: 1,
        generation: 5,
        node: nil,
        parent: nil,
        details: ""
    )
    let b = formatLogLine(
        area: .host,
        event: "mount",
        host: 2,
        generation: 5,
        node: nil,
        parent: nil,
        details: ""
    )

    #expect(a != b)
}

@Test
func test_logIfEnabled_disabledAreaNeverEvaluatesLine() {
    var evaluated = false

    logIfEnabled(
        .tree,
        in: [],
        line: {
            evaluated = true; return "unused"
        },
        output: { _ in }
    )

    #expect(!evaluated)
}

@Test
func test_logIfEnabled_enabledAreaForwardsLineToOutput() {
    var captured: String?

    logIfEnabled(.tree, in: [.tree], line: { "the line" }, output: { captured = $0 })

    #expect(captured == "the line")
}

@Test
func test_logIfEnabled_onlyMatchingAreaFires() {
    var captured: String?

    logIfEnabled(.host, in: [.tree], line: { "unused" }, output: { captured = $0 })

    #expect(captured == nil)
}

@Test
func test_milliseconds_formatsFractionalMilliseconds() {
    #expect(Log.milliseconds(0.01234) == "12.34ms")
    #expect(Log.milliseconds(0) == "0.00ms")
}
