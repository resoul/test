import Foundation

/// Independently toggled area of the Trellis diagnostic pipeline.
///
/// Areas cover the full future pipeline (tree, style, layout, host) even though most of
/// it does not exist yet: turning an area on later needs no new plumbing, only call sites.
///
/// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LogArea: String, Sendable, Hashable, CaseIterable {
    case tree
    case style
    case invalidate
    case snapshot
    case measure
    case place
    case schedule
    case commit
    case arrange
    case layer
    case host
    case event
    case semantics
    case focus
}

/// Parses the `TRELLIS_LOG` environment variable into the set of enabled areas.
///
/// A pure function so area selection is unit-tested without touching `Log.enabled`,
/// which is computed once per process and must not be mutated between tests. `nil`
/// (the variable is unset) returns `fallback`. `"all"` and `"off"` are exact keywords;
/// any other value is a comma-separated area list, and unrecognized names are dropped
/// rather than failing the whole parse.
///
/// Ownership: returns a new set. Isolation: none. Errors: none. Cancellation: not applicable.
func parseLogAreas(_ raw: String?, fallback: Set<LogArea>) -> Set<LogArea> {
    guard let raw else { return fallback }
    switch raw {
    case "all": return Set(LogArea.allCases)
    case "off": return []
    default: return Set(raw.split(separator: ",").compactMap { LogArea(rawValue: String($0)) })
    }
}

/// Builds one correlated diagnostic line with a fixed field order.
///
/// The order — event, host, generation, node, parent, details — is identical for every
/// area, so a line greps the same way regardless of what produced it. Missing
/// `host`/`generation`/`node`/`parent` print as `none`: a tree event before the first
/// host request legitimately has no generation yet, and that is not an error.
///
/// Ownership: returns a new string. Isolation: none. Errors: none. Cancellation: not applicable.
func formatLogLine(
    area: LogArea,
    event: String,
    host: UInt64?,
    generation: UInt64?,
    node: NodeID?,
    parent: NodeID?,
    details: String
) -> String {
    let hostField = "host=" + (host.map(String.init) ?? "none")
    let generationField = "gen=" + (generation.map(String.init) ?? "none")
    let nodeField = node?.description ?? "#none"
    let parentField = "parent=" + (parent?.description ?? "#none")
    let suffix = details.isEmpty ? "" : " \(details)"
    return "[trellis.\(area.rawValue)] \(event) \(hostField) \(generationField) "
        + "\(nodeField) \(parentField)\(suffix)"
}

/// Evaluates and emits `line()` through `output` only if `area` is in `enabledAreas`.
///
/// Isolated from `Log.enabled` and `print` so the gate itself — did a disabled area skip
/// building its line at all — is testable without a subprocess or a frozen global.
///
/// Ownership: no owned state. Isolation: none. Errors: none. Cancellation: not applicable.
func logIfEnabled(
    _ area: LogArea,
    in enabledAreas: Set<LogArea>,
    line: () -> String,
    output: (String) -> Void
) {
    guard enabledAreas.contains(area) else { return }
    output(line())
}

/// Synchronous diagnostic output for the Trellis pipeline, gated by area.
///
/// There is no sink protocol, no actor, no fan-out: this prints directly, because the
/// pipeline it describes is itself synchronous on MainActor with background solver work,
/// and an async logger would misrepresent that. See docs/weave-analysis.md §6.
///
/// A solve duration belongs in `details`, formatted with `Log.milliseconds(_:)`; a cache
/// lookup outcome is `CacheOutcome.hit`/`.miss` interpolated the same way. `ZERO-SIZE` and
/// `OVERFLOW` are conventions on `event`/`details` text for the future `place` area, not
/// separate API: a zero axis is a diagnostic to grep for, not a thrown error.
///
/// Ownership: no owned state beyond the immutable `enabled` set. Isolation: none — called
/// from MainActor and from background solver tasks alike; `print` is thread-safe.
/// Errors: none. Cancellation: not applicable.
public enum Log {
    /// Areas enabled for this process launch, fixed at first access.
    ///
    /// Controlled by the `TRELLIS_LOG` environment variable, readable without a rebuild on
    /// a physical device via the Xcode scheme: `TRELLIS_LOG=all`, `TRELLIS_LOG=off`,
    /// `TRELLIS_LOG=schedule,commit,layer`. Defaults to everything in DEBUG, nothing
    /// otherwise. This is a `let`, not a `var`: tests exercise `parseLogAreas(_:fallback:)`
    /// directly instead of mutating this after first use.
    ///
    /// Ownership: returns a copy of the set. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public static let enabled: Set<LogArea> = {
        #if DEBUG
            let fallback = Set(LogArea.allCases)
        #else
            let fallback = Set<LogArea>()
        #endif
        return parseLogAreas(ProcessInfo.processInfo.environment["TRELLIS_LOG"], fallback: fallback)
    }()

    /// Prints one correlated diagnostic line if `area` is enabled.
    ///
    /// `details` is an `@autoclosure`: when `area` is disabled, its interpolation never
    /// runs, so an expensive description costs nothing on the hot path. `host` and
    /// `generation` are plain values the caller already has in hand — there is no global
    /// "current generation": a background solve and a MainActor commit for a different
    /// host can interleave, and only an explicit host/generation pair tells them apart.
    ///
    /// Ownership: builds and prints a new string; retains nothing. Isolation: none.
    /// Errors: none. Cancellation: not applicable.
    public static func on(
        _ area: LogArea,
        _ event: String,
        host: UInt64? = nil,
        generation: UInt64? = nil,
        node: NodeID? = nil,
        parent: NodeID? = nil,
        _ details: @autoclosure () -> String = ""
    ) {
        logIfEnabled(
            area,
            in: enabled,
            line: {
                formatLogLine(
                    area: area,
                    event: event,
                    host: host,
                    generation: generation,
                    node: node,
                    parent: parent,
                    details: details()
                )
            },
            output: { print($0) }
        )
    }

    /// Formats a duration as whole-plus-fractional milliseconds for log details, e.g. `12.34ms`.
    ///
    /// Ownership: returns a new string. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func milliseconds(_ duration: TimeInterval) -> String {
        String(format: "%.2fms", duration * 1000)
    }
}

/// Outcome of a single measure/solve cache lookup, printed as `hit`/`miss` in log details.
///
/// Ownership: the value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CacheOutcome: String, Sendable {
    case hit
    case miss
}
