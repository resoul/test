import Foundation

#if canImport(os)
    import os
#endif

/// Marks the stretches of work that decide how smooth the screen is — a layout pass, drawing a
/// layer, decoding an image, loading a page — so that Instruments shows where the time goes.
///
/// The marks are signposts of the subsystem `Trace.subsystem`. While nothing records them
/// (Instruments is not attached and no observer is installed) a mark costs one check, and its
/// detail text is not built. On a platform without the `os` framework nothing is marked.
public enum Trace {
    /// The subsystem the signposts belong to.
    public static let subsystem = "Espalier"

    /// What a mark is about. One name is one row in Instruments.
    public enum Name: String, Sendable, CaseIterable {
        /// A layout pass solved on the main thread.
        case layoutOnMain = "layout.main"
        /// A layout pass solved on the host's own thread.
        case layoutInBackground = "layout.background"
        /// Putting a solved layout into the tree: frames, mounting, the screen's nodes told.
        case layoutApply = "layout.apply"
        /// Drawing the content of one node into a bitmap.
        case draw
        /// Decoding one image's bytes into pixels.
        case decode
        /// One page of a list on its way, from the request to the loader's answer.
        case pageLoad = "page.load"
    }

    /// Which end of a stretch of work a record is, or a single moment.
    public enum Phase: Sendable, Equatable {
        case begin
        case end
        case event
    }

    /// What an observer is told.
    public struct Record: Sendable, Equatable {
        public var name: Name
        public var phase: Phase
        /// What the mark says about this one occurrence — a host's number, an image's size.
        public var detail: String

        public init(name: Name, phase: Phase, detail: String) {
            self.name = name
            self.phase = phase
            self.detail = detail
        }
    }

    /// A stretch of work that has begun, to be ended with ``end(_:)``.
    public struct Interval: Sendable {
        let name: Name
        let detail: String
        #if canImport(os)
            let state: OSSignpostIntervalState?
        #endif
    }

    /// Marks the start of a stretch of work. Call ``end(_:)`` with the result exactly once, on
    /// any thread.
    ///
    /// - Parameter detail: What distinguishes this occurrence; built only when someone records.
    public static func begin(_ name: Name, _ detail: @autoclosure () -> String = "") -> Interval {
        let observing = observers.hasAny
        #if canImport(os)
            let signposting = signposter.isEnabled
            guard observing || signposting else {
                return Interval(name: name, detail: "", state: nil)
            }

            let text = detail()
            if observing { observers.tell(Record(name: name, phase: .begin, detail: text)) }
            let state = signposting ? beginSignpost(name, text) : nil
            return Interval(name: name, detail: text, state: state)
        #else
            guard observing else { return Interval(name: name, detail: "") }

            let text = detail()
            observers.tell(Record(name: name, phase: .begin, detail: text))
            return Interval(name: name, detail: text)
        #endif
    }

    /// Marks the end of the stretch of work ``begin(_:_:)`` started.
    public static func end(_ interval: Interval) {
        if observers.hasAny {
            observers.tell(Record(name: interval.name, phase: .end, detail: interval.detail))
        }
        #if canImport(os)
            if let state = interval.state { endSignpost(interval.name, state) }
        #endif
    }

    /// Marks a single moment.
    public static func event(_ name: Name, _ detail: @autoclosure () -> String = "") {
        let observing = observers.hasAny
        #if canImport(os)
            let signposting = signposter.isEnabled
            guard observing || signposting else { return }

            let text = detail()
            if observing { observers.tell(Record(name: name, phase: .event, detail: text)) }
            if signposting { eventSignpost(name, text) }
        #else
            guard observing else { return }

            observers.tell(Record(name: name, phase: .event, detail: detail()))
        #endif
    }

    /// Runs `body` as one stretch of work.
    public static func measure<Result>(
        _ name: Name,
        _ detail: @autoclosure () -> String = "",
        _ body: () throws -> Result
    ) rethrows -> Result {
        let interval = begin(name, detail())
        defer { end(interval) }
        return try body()
    }

    /// Tells `handler` of every record made from now on, on whichever thread makes it, until the
    /// returned token is cancelled. Meant for tests and tools: a handler runs inside the code it
    /// watches, so it must be quick and must not call back into the tree.
    public static func observe(_ handler: @escaping @Sendable (Record) -> Void) -> Observation {
        Observation(id: observers.add(handler))
    }

    /// An installed observer. Cancel it to stop being told.
    public struct Observation: Sendable {
        let id: Int

        public func cancel() { observers.remove(id) }
    }

    // MARK: Observers

    private static let observers = Observers()

    #if canImport(os)
        private final class Observers: Sendable {
            private struct State {
                var next = 0
                var handlers: [Int: @Sendable (Record) -> Void] = [:]
            }

            private let state = OSAllocatedUnfairLock(initialState: State())

            var hasAny: Bool { state.withLock { !$0.handlers.isEmpty } }

            func add(_ handler: @escaping @Sendable (Record) -> Void) -> Int {
                state.withLock {
                    $0.next += 1
                    $0.handlers[$0.next] = handler
                    return $0.next
                }
            }

            func remove(_ id: Int) {
                state.withLock { $0.handlers[id] = nil }
            }

            func tell(_ record: Record) {
                let handlers = state.withLock { Array($0.handlers.values) }
                for handler in handlers { handler(record) }
            }
        }
    #else
        // Without the `os` framework there is nothing to mark and nothing to lock with: observers
        // are not kept.
        private final class Observers: Sendable {
            var hasAny: Bool { false }
            func add(_ handler: @escaping @Sendable (Record) -> Void) -> Int { 0 }
            func remove(_ id: Int) {}
            func tell(_ record: Record) {}
        }
    #endif

    // MARK: Signposts

    #if canImport(os)
        private static let signposter = OSSignposter(subsystem: subsystem, category: "Pipeline")

        // A signpost's name must be a literal, so each name has its own call.
        private static func beginSignpost(_ name: Name, _ detail: String) -> OSSignpostIntervalState
        {
            let id = signposter.makeSignpostID()
            switch name {
            case .layoutOnMain:
                return signposter.beginInterval(
                    "layout.main",
                    id: id,
                    "\(detail, privacy: .public)"
                )
            case .layoutInBackground:
                return signposter.beginInterval(
                    "layout.background",
                    id: id,
                    "\(detail, privacy: .public)"
                )
            case .layoutApply:
                return signposter.beginInterval(
                    "layout.apply",
                    id: id,
                    "\(detail, privacy: .public)"
                )
            case .draw:
                return signposter.beginInterval("draw", id: id, "\(detail, privacy: .public)")
            case .decode:
                return signposter.beginInterval("decode", id: id, "\(detail, privacy: .public)")
            case .pageLoad:
                return signposter.beginInterval("page.load", id: id, "\(detail, privacy: .public)")
            }
        }

        private static func endSignpost(_ name: Name, _ state: OSSignpostIntervalState) {
            switch name {
            case .layoutOnMain: signposter.endInterval("layout.main", state)
            case .layoutInBackground: signposter.endInterval("layout.background", state)
            case .layoutApply: signposter.endInterval("layout.apply", state)
            case .draw: signposter.endInterval("draw", state)
            case .decode: signposter.endInterval("decode", state)
            case .pageLoad: signposter.endInterval("page.load", state)
            }
        }

        private static func eventSignpost(_ name: Name, _ detail: String) {
            switch name {
            case .layoutOnMain: signposter.emitEvent("layout.main", "\(detail, privacy: .public)")
            case .layoutInBackground:
                signposter.emitEvent("layout.background", "\(detail, privacy: .public)")
            case .layoutApply: signposter.emitEvent("layout.apply", "\(detail, privacy: .public)")
            case .draw: signposter.emitEvent("draw", "\(detail, privacy: .public)")
            case .decode: signposter.emitEvent("decode", "\(detail, privacy: .public)")
            case .pageLoad: signposter.emitEvent("page.load", "\(detail, privacy: .public)")
            }
        }
    #endif
}
