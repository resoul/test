import Darwin
import Foundation
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// R06 (implementation-plan-6.md §6.1): the "bounded recorder" the native performance harness
// needs — the real-app-process counterpart to `Bench/Sources/TrellisBench/main.swift`'s
// `Samples`/`FixtureResult`/`Report`, which the plan explicitly says is not itself evidence for
// UIKit/AppKit scrolling ("CLI Bench не выдаётся за замер UIKit scrolling"). This file collects
// the same shape of numbers from inside `Playground/iOS`, `Playground/tvOS`, `Playground/macOS`
// instead of a bare `CALayer`/`NodeHostBridge` with no window. Bounded by construction: a fixed
// per-series `capacity` (default 5000 samples) with overflow counted, not silently grown, and
// no accumulation of models or an unbounded event log — only scalar timings/counters survive.

/// Bounded wall-clock samples in milliseconds with p50/p95/p99 (the plan's own quantile list —
/// one more than `Bench`'s `Samples`, which only tracks p50/p95).
///
/// Ownership: value type, copied by its owning fixture. Isolation: none (compute on whichever
/// actor collected it). Errors: none — an empty series reports zeroes. Cancellation: not
/// applicable.
public struct PerfSamples: Codable {
    private var values: [Double] = []
    public private(set) var droppedCount: Int = 0
    public let capacity: Int

    public init(capacity: Int = 5000) {
        self.capacity = Swift.max(1, capacity)
    }

    /// Records one sample, or counts it as dropped once `capacity` is reached.
    ///
    /// Ownership: the value is copied. Isolation: none. Errors: non-finite samples are dropped
    /// without counting (they cannot come from a real duration). Cancellation: not applicable.
    public mutating func add(_ ms: Double) {
        guard ms.isFinite else { return }
        guard values.count < capacity else {
            droppedCount += 1
            return
        }
        values.append(ms)
    }

    public var count: Int { values.count }
    public var p50: Double { quantile(0.5) }
    public var p95: Double { quantile(0.95) }
    public var p99: Double { quantile(0.99) }
    public var max: Double { values.max() ?? 0 }
    public var min: Double { values.min() ?? 0 }

    private func quantile(_ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))
        return sorted[index]
    }

    enum CodingKeys: String, CodingKey { case p50, p95, p99, min, max, count, dropped }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(perfRound(p50), forKey: .p50)
        try container.encode(perfRound(p95), forKey: .p95)
        try container.encode(perfRound(p99), forKey: .p99)
        try container.encode(perfRound(min), forKey: .min)
        try container.encode(perfRound(max), forKey: .max)
        try container.encode(count, forKey: .count)
        try container.encode(droppedCount, forKey: .dropped)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capacity = Int.max
        values = []
        droppedCount = try container.decode(Int.self, forKey: .dropped)
        // Decoding never needs to reconstruct the raw series — only the aggregates a
        // previously-written report already carries; `values` stays empty and the aggregates
        // below are exposed through the same computed properties by re-injecting one sample
        // per distinct aggregate is not attempted (lossy either way) — callers that need the
        // original series read `timingsMs` from the JSON directly instead of round-tripping.
        _ = try container.decode(Double.self, forKey: .p50)
        _ = try container.decode(Double.self, forKey: .p95)
        _ = try container.decode(Double.self, forKey: .p99)
        _ = try container.decode(Double.self, forKey: .min)
        _ = try container.decode(Double.self, forKey: .max)
        _ = try container.decode(Int.self, forKey: .count)
    }
}

private func perfRound(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

/// Times `body` in milliseconds using the monotonic clock — the same primitive `Bench` uses,
/// duplicated here rather than shared across the package/app boundary (`Bench` is a standalone
/// SPM executable; `Playground` apps do not depend on it).
///
/// Ownership: returns a value. Isolation: none — `body` runs on whatever actor calls this.
/// Errors: none. Cancellation: not applicable; `body` is synchronous.
public func perfElapsedMs(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

/// One named fixture's collected metrics — mirrors `Bench.FixtureResult`'s JSON shape so the
/// same downstream tooling (a report reader, a comparison script) can read either source.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PerfFixtureResult: Codable {
    public let name: String
    public var parameters: [String: Int] = [:]
    public var timingsMs: [String: PerfSamples] = [:]
    public var counters: [String: Int] = [:]
    public var notes: [String] = []

    public init(name: String, parameters: [String: Int] = [:]) {
        self.name = name
        self.parameters = parameters
    }
}

/// Device/OS/build identity for one recording — the plan's "device/OS/build/refresh" fields,
/// plus the source revision a comparison across sessions needs to mean anything.
///
/// Ownership: value type. Isolation: none. Errors: an unavailable field reports `"unknown"`/
/// `nil` rather than guessing. Cancellation: not applicable.
public struct PerfEnvironment: Codable {
    public let date: String
    public let deviceModel: String
    public let os: String
    public let configuration: String
    public let sourceRevision: String
    public let refreshRateHz: Int?

    public init(sourceRevision: String) {
        date = ISO8601DateFormatter().string(from: Date())
        deviceModel = PerfEnvironment.currentDeviceModel()
        os = ProcessInfo.processInfo.operatingSystemVersionString
        #if DEBUG
            configuration = "debug"
        #else
            configuration = "release"
        #endif
        self.sourceRevision = sourceRevision
        refreshRateHz = PerfEnvironment.currentRefreshRateHz()
    }

    /// The hardware model identifier (e.g. `iPhone16,1`, `MacBookPro18,3`, `AppleTV11,1`) —
    /// works identically on device and Simulator (Simulator reports the *host* Mac's model,
    /// which is itself useful evidence: Simulator timing is host-machine-dependent, never a
    /// substitute for device numbers, matching AGENTS.md's "проверка на симуляторе не
    /// выдаётся за проверку на устройстве").
    private static func currentDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("hw.model", &buffer, &size, nil, 0)
        guard result == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    /// Best-effort display refresh rate. `nil` (not `0`) means "could not be determined" —
    /// many non-ProMotion Mac displays report `0` from `CGDisplayMode.refreshRate` itself,
    /// which this does not silently promote to a false `60`.
    private static func currentRefreshRateHz() -> Int? {
        #if os(iOS) || os(tvOS)
            let hz = UIScreen.main.maximumFramesPerSecond
            return hz > 0 ? hz : nil
        #elseif os(macOS)
            guard let screen = NSScreen.main,
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(truncating: number)
            guard let mode = CGDisplayCopyDisplayMode(displayID), mode.refreshRate > 0 else {
                return nil
            }
            return Int(mode.refreshRate.rounded())
        #else
            return nil
        #endif
    }
}

/// A full recording session: environment plus every fixture measured during it. JSON-shaped
/// like `Bench.Report` (with `PerfEnvironment` folded in instead of separate top-level fields)
/// so a comparison script can treat both sources uniformly; also exports flat CSV rows since
/// the plan asks for both ("Экспорт JSON/CSV").
///
/// Ownership: value type; the recorder below owns building one of these. Isolation: none.
/// Errors: none. Cancellation: not applicable.
public struct PerfReport: Codable {
    public let environment: PerfEnvironment
    public let warmupIterations: Int
    public let repeatIterations: Int
    public var fixtures: [PerfFixtureResult] = []

    public init(environment: PerfEnvironment, warmupIterations: Int, repeatIterations: Int) {
        self.environment = environment
        self.warmupIterations = warmupIterations
        self.repeatIterations = repeatIterations
    }

    /// Pretty-printed, key-sorted JSON — stable across runs so a diff shows only real changes.
    public func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// One row per (fixture, metric): `fixture,metric,p50,p95,p99,min,max,count,dropped`. Every
    /// row repeats the environment/revision columns so a spreadsheet or `awk` script never needs
    /// to join back against the JSON to know what produced a row.
    public func csvText() -> String {
        var lines = [
            "fixture,metric,p50_ms,p95_ms,p99_ms,min_ms,max_ms,count,dropped,"
                + "device,os,configuration,source_revision,refresh_hz,date"
        ]
        let env = environment
        let shared =
            "\(csvField(env.deviceModel)),\(csvField(env.os)),\(csvField(env.configuration)),"
            + "\(csvField(env.sourceRevision)),\(env.refreshRateHz.map(String.init) ?? ""),"
            + "\(csvField(env.date))"
        for fixture in fixtures {
            for (metric, samples) in fixture.timingsMs.sorted(by: { $0.key < $1.key }) {
                lines.append(
                    "\(csvField(fixture.name)),\(csvField(metric)),\(samples.p50),\(samples.p95),"
                        + "\(samples.p99),\(samples.min),\(samples.max),\(samples.count),"
                        + "\(samples.droppedCount),\(shared)"
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// Parses the reproducible launch configuration the plan's §6.1 asks for: scenario id, seed,
/// item count, viewport, and repeat count, all as `CommandLine.arguments` flags — the same
/// pattern `Scenario.initialIndex`/`Scenario.dumpsAccessibility` already use for `--scene`/
/// `--dump-accessibility`. An XCUITest launches the app with these via
/// `XCUIApplication.launchArguments`, so the same flags work from a manual Simulator launch
/// (`xcrun simctl launch <device> <bundle-id> --perf-scenario … `) and from an automated run.
///
/// Ownership: value type, read once at launch. Isolation: none. Errors: a missing/malformed
/// flag falls back to a documented default rather than crashing. Cancellation: not applicable.
public struct PerfLaunchConfiguration {
    public let isRequested: Bool
    public let scenario: String
    public let seed: UInt64
    public let itemCount: Int
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let repeatIterations: Int
    public let warmupIterations: Int
    public let outputPath: String?
    public let sourceRevision: String

    public init(arguments: [String] = CommandLine.arguments) {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        isRequested = arguments.contains("--perf-run")
        scenario = value(for: "--perf-scenario") ?? "text-list"
        seed = value(for: "--perf-seed").flatMap { UInt64($0) } ?? 7
        itemCount = value(for: "--perf-count").flatMap { Int($0) } ?? 1000
        if let viewport = value(for: "--perf-viewport") {
            let parts = viewport.split(separator: "x").compactMap { Double($0) }
            viewportWidth = parts.count == 2 ? parts[0] : 390
            viewportHeight = parts.count == 2 ? parts[1] : 844
        } else {
            viewportWidth = 390
            viewportHeight = 844
        }
        repeatIterations = value(for: "--perf-repeats").flatMap { Int($0) } ?? 20
        warmupIterations = value(for: "--perf-warmup").flatMap { Int($0) } ?? 3
        outputPath = value(for: "--perf-output")
        sourceRevision = value(for: "--perf-revision") ?? "unknown"
    }
}

/// Peak/resident bitmap and process memory the plan asks for alongside timings — the same
/// `mach_task_basic_info`/`rusage` primitives `Bench` already uses, duplicated for the same
/// standalone-target reason as `perfElapsedMs`.
///
/// Ownership: returns a value. Isolation: none. Errors: an unreadable value reports `-1`, never
/// a guessed number. Cancellation: not applicable.
public enum PerfMemory {
    public static func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1_048_576
    }

    public static func peakResidentMiB() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Double(usage.ru_maxrss) / 1_048_576
    }
}
