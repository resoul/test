// What a scroll over the demo's lazy lists costs on the main thread: the passes the host
// runs as the window moves, split into their parts, and the drawing after each. Run:
// `swift run -c release ScrollBench` (options: `--steps <n>`, `--step <points>`).
import Foundation
import LayoutCore
import Nodes
import NodesRender
import QuartzCore

@MainActor
func run() {
    var steps = 200
    var step = 300.0
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--steps": steps = Int(arguments.next() ?? "") ?? steps
        case "--step": step = Double(arguments.next() ?? "") ?? step
        default: break
        }
    }

    let model = DemoModel()
    guard let screen = model.screen as? Screen, let feed = screen.feed.content as? Feed else {
        fatalError("the demo screen changed its shape")
    }
    let host = NodeHost(root: screen, size: LayoutSize(width: 640, height: 600))
    host.scale = 2
    let renderer = LayerRenderer()
    let container = CALayer()
    var solve = Duration.zero
    var elements = 0
    host.onLayoutReport = { report in
        solve += report.duration
        elements = report.elements
    }
    host.layoutIfNeeded()
    renderer.render(screen, in: container, scale: 2)
    host.didRender()

    for (name, list) in [("grid", feed.grid as Node), ("lines", feed.lines as Node)] {
        guard let start = screen.feed.frame(of: list)?.origin.y else { continue }

        screen.feed.contentOffset = LayoutPoint(x: 0, y: start)
        host.layoutIfNeeded()
        renderer.render(screen, in: container, scale: 2)
        host.didRender()

        var passTimes: [Double] = []
        var solveTimes: [Double] = []
        var renderTimes: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<steps {
            let offset = screen.feed.contentOffset
            screen.feed.contentOffset = LayoutPoint(x: 0, y: offset.y + step)
            let passes = host.passes
            solve = .zero
            let began = clock.now
            host.layoutIfNeeded()
            let laidOut = clock.now
            if host.needsRender {
                renderer.render(screen, in: container, scale: 2)
            } else {
                renderer.renderScrolls(host.scrolledSinceRender)
            }
            host.didRender()
            guard host.passes > passes else { continue }

            passTimes.append(milliseconds(laidOut - began))
            solveTimes.append(milliseconds(solve))
            renderTimes.append(milliseconds(clock.now - laidOut))
        }
        print(
            "\(name): \(passTimes.count) of \(steps) moves of \(Int(step)) pt laid out, "
                + "\(elements) elements in the tree"
        )
        print("  layout pass  \(summary(passTimes))")
        print("    engine     \(summary(solveTimes))")
        print(
            "    the rest   \(summary(zip(passTimes, solveTimes).map { $0 - $1 }))"
                + "  (layoutSpec, update, apply, mount)"
        )
        print("  drawing      \(summary(renderTimes))")
    }
    host.detach()
}

func summary(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "—" }

    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let p90 = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
    return String(format: "median %6.2f ms  p90 %6.2f ms  max %6.2f ms", median, p90, sorted.last!)
}

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
}

MainActor.assumeIsolated { run() }
