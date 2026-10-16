// Dependency tracking. Reading a `State` or a `Computed` while an `Observer` tracks records
// that value, with its version, as a dependency of that observer. A change pushes "maybe
// stale" down the graph at once; whether anything really changed is pulled lazily — an
// observer runs only if a value it read has a newer version than the one it saw. That keeps
// updates glitch-free (a diamond of computed values is seen consistent) and minimal (a
// computed value that comes out equal stops the update there).
//
// Everything lives on the main actor, so the tracking state is plain main-actor data: no
// locks and no unchecked sendability.

/// A value that can be read under tracking: `State` or `Computed`.
@MainActor
protocol Source: AnyObject {
    /// Grows every time the value changes; equal writes leave it as it is.
    var version: UInt64 { get }

    /// Brings the value up to date (a `Computed` recomputes if it has to).
    func refresh()

    func addDependent(_ dependent: any Dependent)
    func removeDependent(_ dependent: any Dependent)
}

/// Something that reads sources: an `Observer` or a `Computed`.
@MainActor
protocol Dependent: AnyObject {
    /// A source it read may have changed.
    func sourceMayHaveChanged()
}

/// The dependents of a source, held weakly: a dependent nobody keeps is simply gone.
@MainActor
struct Dependents {
    private final class Box {
        weak var dependent: (any Dependent)?

        init(_ dependent: any Dependent) {
            self.dependent = dependent
        }
    }

    private var boxes: [ObjectIdentifier: Box] = [:]

    mutating func add(_ dependent: any Dependent) {
        boxes[ObjectIdentifier(dependent)] = Box(dependent)
    }

    mutating func remove(_ dependent: any Dependent) {
        boxes[ObjectIdentifier(dependent)] = nil
    }

    /// Tells every live dependent, and forgets the dead ones.
    mutating func notify() {
        var dead: [ObjectIdentifier] = []
        for (key, box) in boxes {
            if let dependent = box.dependent {
                dependent.sourceMayHaveChanged()
            } else {
                dead.append(key)
            }
        }
        for key in dead {
            boxes[key] = nil
        }
    }
}

/// The sources one dependent read in its last tracked run, and the versions it saw.
@MainActor
struct Reads {
    private(set) var entries: [ObjectIdentifier: (source: any Source, version: UInt64)] = [:]

    mutating func record(_ source: any Source) {
        let key = ObjectIdentifier(source)
        if entries[key] == nil {
            entries[key] = (source, source.version)
        }
    }

    /// Whether any source now has a version other than the one read. Sources are brought
    /// up to date first, so a computed value that recomputes to an equal result does not
    /// count as a change.
    func changed() -> Bool {
        for entry in entries.values {
            entry.source.refresh()
            if entry.source.version != entry.version { return true }
        }
        return false
    }

    /// Subscribes `dependent` to the sources of `self` and unsubscribes it from those of
    /// `previous` that are no longer read.
    func subscribe(_ dependent: any Dependent, replacing previous: Reads) {
        for (key, entry) in previous.entries where entries[key] == nil {
            entry.source.removeDependent(dependent)
        }
        for (key, entry) in entries where previous.entries[key] == nil {
            entry.source.addDependent(dependent)
        }
    }

    func unsubscribe(_ dependent: any Dependent) {
        for entry in entries.values {
            entry.source.removeDependent(dependent)
        }
    }
}

/// The reads of the innermost run being tracked.
@MainActor
enum Tracking {
    private static var current: Reads?

    static func record(_ source: any Source) {
        current?.record(source)
    }

    /// Runs `body`, collecting what it reads into `reads` — also what it read before it
    /// threw. Nested tracking collects separately: an observer inside another one does not
    /// leak its reads to the outer.
    static func collect<Result>(
        into reads: inout Reads,
        _ body: () throws -> Result
    ) rethrows -> Result {
        let outer = current
        current = Reads()
        defer {
            reads = current ?? Reads()
            current = outer
        }
        return try body()
    }

    static func withoutTracking<Result>(_ body: () throws -> Result) rethrows -> Result {
        let outer = current
        current = nil
        defer { current = outer }
        return try body()
    }
}

/// Runs `body` without recording its reads as dependencies of the observer that is
/// tracking — for values that are only looked at, not depended on.
///
/// Ownership: returns what `body` returns. Isolation: MainActor. Errors: rethrows `body`'s
/// error. Cancellation: not applicable.
@MainActor
public func untracked<Result>(_ body: () throws -> Result) rethrows -> Result {
    try Tracking.withoutTracking(body)
}
