import Foundation

// Solve time of the engine under test and of the previous engine on the same trees, and how
// fast a cancelled solve stops. Prints a Markdown report.

struct Fixture {
    let name: String
    let tree: Box
    /// Sizes the tree is laid out at, in turn: more than one makes every pass a new width.
    let sizes: [(width: Double, height: Double)]
}

let fixtures: [Fixture] = [
    Fixture(name: "wide-100", tree: wideTree(count: 100), sizes: [(600, 4000)]),
    Fixture(name: "wide-1000", tree: wideTree(count: 1000), sizes: [(600, 4000)]),
    Fixture(
        name: "wide-1000-resize",
        tree: wideTree(count: 1000),
        sizes: (0..<10).map { (Double(400 + $0 * 40), 4000) }
    ),
    Fixture(
        name: "single-line-5000",
        tree: wideTree(count: 5000, wraps: false),
        sizes: [(200_000, 100)]
    ),
    Fixture(name: "deep-30", tree: deepTree(depth: 30), sizes: [(800, 2000)]),
    Fixture(name: "deep-1500", tree: deepTree(depth: 1500), sizes: [(800, 30_000)]),
    // Natural height is 2805: every level shrinks.
    Fixture(name: "chain-shrink-200", tree: deepTree(depth: 200), sizes: [(800, 1400)]),
    Fixture(
        name: "chain-grow-200",
        tree: deepTree(depth: 200, levelsGrow: true),
        sizes: [(800, 4000)]
    ),
    Fixture(name: "text-list-1000", tree: textList(count: 1000), sizes: [(390, 100_000)]),
    Fixture(
        name: "text-list-1000-resize",
        tree: textList(count: 1000),
        sizes: (0..<10).map { (Double(320 + $0 * 20), 100_000) }
    ),
    Fixture(name: "cards-300", tree: cardList(count: 300), sizes: [(390, 100_000)]),
]

/// Fixtures whose cancellation latency is measured.
let cancellable: Set<String> = ["deep-1500", "single-line-5000", "text-list-1000"]

struct Samples {
    private(set) var values: [Double] = []

    mutating func add(_ value: Double) { values.append(value) }

    func quantile(_ q: Double) -> Double {
        guard !values.isEmpty else { return .nan }

        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    var median: Double { quantile(0.5) }
}

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
}

func format(_ value: Double) -> String {
    guard value.isFinite else { return "—" }

    return value < 1 ? String(format: "%.3f", value) : String(format: "%.2f", value)
}

enum EngineKind: String, CaseIterable {
    case previous
    case current
}

@MainActor
func prepare(_ kind: EngineKind, _ fixture: Fixture) -> [PreparedLayout] {
    fixture.sizes.map { size in
        switch kind {
        case .previous: preparePrevious(fixture.tree, width: size.width, height: size.height)
        case .current: prepareCurrent(fixture.tree, width: size.width, height: size.height)
        }
    }
}

/// Solve times in milliseconds, and the number of frames of the first pass.
func time(_ layouts: [PreparedLayout], iterations: Int) -> (Samples, Int) {
    let clock = ContinuousClock()
    var frames = 0
    for index in 0..<3 {
        frames = (try? layouts[index % layouts.count].run { false }) ?? -1
    }
    var samples = Samples()
    for index in 0..<iterations {
        let layout = layouts[index % layouts.count]
        samples.add(milliseconds(clock.measure { _ = try? layout.run { false } }))
    }
    return (samples, frames)
}

/// Stack of the thread a cancelled solve runs on. The solver recurses once per nesting level,
/// and a pool thread's stack (512 KiB on Apple platforms) does not hold the deepest trees;
/// a background layout in the app runs on a thread of this size too.
let solverStackSize = 8 << 20

/// What the solving thread reports back.
enum SolveEvent: Sendable {
    case started
    case finished(ContinuousClock.Instant)
}

/// Time from cancelling a running solve to its thread finishing, in milliseconds. The cancel
/// comes a quarter of a typical solve after the thread starts running.
func cancelLatency(_ layout: PreparedLayout, solve: Double, iterations: Int) async -> (
    Samples, finishedFirst: Int
) {
    let clock = ContinuousClock()
    var samples = Samples()
    var finishedFirst = 0
    for _ in 0..<iterations {
        let (events, report) = AsyncStream.makeStream(of: SolveEvent.self)
        let thread = Thread {
            report.yield(.started)
            _ = try? layout.run { Thread.current.isCancelled }
            report.yield(.finished(clock.now))
            report.finish()
        }
        thread.stackSize = solverStackSize
        thread.start()
        var reports = events.makeAsyncIterator()
        // A thread cancelled before its body starts never runs it, so the cancel waits until
        // the body is certainly running.
        _ = await reports.next()
        try? await Task.sleep(for: .microseconds(max(50, Int(solve * 250))))
        let cancelled = clock.now
        thread.cancel()
        guard case let .finished(finished) = await reports.next() else { continue }

        if finished > cancelled {
            samples.add(milliseconds(finished - cancelled))
        } else {
            finishedFirst += 1
        }
    }
    return (samples, finishedFirst)
}

// MARK: - Run

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var only: String?
var engines = EngineKind.allCases
var iterations = 20
while let argument = arguments.next() {
    switch argument {
    case "--only": only = arguments.next()
    case "--iterations": iterations = arguments.next().flatMap(Int.init) ?? iterations
    case "--engine":
        engines = arguments.next().flatMap(EngineKind.init(rawValue:)).map { [$0] } ?? []
    default:
        FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
        exit(2)
    }
}

var solveRows: [String] = []
var cancelRows: [String] = []
for fixture in fixtures where only == nil || only == fixture.name {
    var medians: [EngineKind: Double] = [:]
    var p95: [EngineKind: Double] = [:]
    var frames: [EngineKind: Int] = [:]
    for kind in engines {
        let layouts = prepare(kind, fixture)
        let (samples, count) = time(layouts, iterations: iterations)
        medians[kind] = samples.median
        p95[kind] = samples.quantile(0.95)
        frames[kind] = count

        if cancellable.contains(fixture.name) {
            let (latency, finishedFirst) = await cancelLatency(
                layouts[0],
                solve: samples.median,
                iterations: iterations
            )
            cancelRows.append(
                "| \(fixture.name) | \(kind.rawValue) | \(format(samples.median)) | "
                    + "\(format(latency.median)) | \(format(latency.quantile(0.95))) | "
                    + "\(format(latency.quantile(1))) | \(finishedFirst) |"
            )
        }
    }

    let previous = medians[.previous] ?? .nan
    let current = medians[.current] ?? .nan
    let note = frames[.previous] == frames[.current] ? "" : " frames \(frames)"
    solveRows.append(
        "| \(fixture.name) | \(fixture.tree.count) | \(format(previous)) | \(format(current)) | "
            + "\(format(p95[.previous] ?? .nan)) | \(format(p95[.current] ?? .nan)) | "
            + "\(String(format: "%.2f", current / previous))\(note) |"
    )
    FileHandle.standardError.write(Data("done \(fixture.name)\n".utf8))
}

print("Solve, ms (\(iterations) passes after 3 warm-up; the tree is prepared before timing).")
print()
print(
    "| Fixture | Nodes | previous p50 | current p50 | previous p95 | current p95 | current / previous |"
)
print("|---|---|---|---|---|---|---|")
solveRows.forEach { print($0) }
if !cancelRows.isEmpty {
    print()
    print("Cancellation: from `cancel()` to the solving thread finishing, ms.")
    print()
    print(
        "| Fixture | Engine | solve p50 | latency p50 | latency p95 | latency max | finished before cancel |"
    )
    print("|---|---|---|---|---|---|---|")
    cancelRows.forEach { print($0) }
}
