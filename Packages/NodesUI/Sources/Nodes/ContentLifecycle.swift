import Foundation

/// Work needed for content, independently of whether that work has finished.
///
/// These are simultaneous flags, not sequential loading stages. ``requirements`` expands
/// visible demand to display, measurement, and data demand. Measurement can also be
/// requested on its own, before content enters a display range.
public struct ContentDemand: OptionSet, Sendable, Hashable {
    /// The bits identifying the requested work.
    public let rawValue: UInt8

    /// Creates demand from its flags.
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Obtain data or resource bytes, including for items without a live node.
    public static let preload = ContentDemand(rawValue: 1 << 0)

    /// Prepare content for nearby display, including missing data and measurement.
    public static let display = ContentDemand(rawValue: 1 << 1)

    /// Content intersects an active viewport; allow effects intended for a viewer.
    /// This does not mean its data, geometry, or drawing is ready.
    public static let visible = ContentDemand(rawValue: 1 << 2)

    /// Prepare geometry, even when no drawing or resource fetch is needed yet.
    public static let measure = ContentDemand(rawValue: 1 << 3)

    /// The requested flags with all implied work included.
    ///
    /// Display requires preload and measurement; visible requires display. These
    /// implications do not impose execution order: available text can be measured while
    /// image bytes are still loading. Resource owners enforce their actual dependencies.
    public var requirements: ContentDemand {
        var result = self
        if result.contains(.visible) { result.insert(.display) }
        if result.contains(.display) { result.formUnion([.preload, .measure]) }
        return result
    }

    /// Whether this demand needs work in the given phase, including implied work.
    public func requires(_ phase: PreparationPhase) -> Bool {
        let flags = requirements
        switch phase {
        case .data: return flags.contains(.preload)
        case .measurement: return flags.contains(.measure)
        case .drawing: return flags.contains(.display)
        }
    }
}

/// Independently prepared parts of an item's content.
public enum PreparationPhase: Sendable, Hashable, CaseIterable {
    /// Data or resource bytes used by this item.
    case data
    /// Geometry calculated for the item's current constraints and environment.
    case measurement
    /// Content prepared for drawing, such as a decoded image or rendered text.
    case drawing
}

/// Readiness of one preparation phase for the current content key.
public enum PreparationState: Sendable, Hashable {
    /// No retained result and no current attempt.
    case idle
    /// One attempt is in flight; the phase is not ready yet.
    case running
    /// The owner has a usable result for the current key.
    case ready
    /// The last attempt failed; retry must be requested explicitly.
    case failed
    /// The current client stopped waiting; no result is ready for this phase.
    case cancelled
}

/// How an attempt ended; cancellation is separate from failure.
public enum PreparationOutcome: Sendable, Hashable {
    /// The owner can retain and use the result.
    case ready
    /// The attempt failed; the owner retains any error details it needs to present.
    case failed
    /// The client stopped waiting, without treating it as an error.
    case cancelled
}

/// Readiness of data, geometry, and drawing, without implying visibility.
public struct ContentReadiness: Sendable, Hashable {
    /// Whether data is ready or being obtained.
    public private(set) var data: PreparationState = .idle

    /// Whether geometry is ready or being measured.
    public private(set) var measurement: PreparationState = .idle

    /// Whether drawing content is ready or being prepared.
    public private(set) var drawing: PreparationState = .idle

    /// Creates readiness without retained results or running attempts.
    public init() {}

    /// The state of one independent preparation phase.
    public subscript(_ phase: PreparationPhase) -> PreparationState {
        switch phase {
        case .data: return data
        case .measurement: return measurement
        case .drawing: return drawing
        }
    }

    fileprivate mutating func set(_ state: PreparationState, for phase: PreparationPhase) {
        switch phase {
        case .data: data = state
        case .measurement: measurement = state
        case .drawing: drawing = state
        }
    }
}

/// Identifies one client's attempt for a content key and preparation phase.
///
/// Pass the ticket to asynchronous work instead of a live node. Only the lifecycle that
/// issued it can accept its completion. A reset, release, or cancellation makes it stale,
/// even if the same key and phase are requested again later.
public struct PreparationTicket<Key: Hashable & Sendable>: Sendable, Hashable {
    /// The item identity, revision, constraints, and environment supplied by the owner.
    public let key: Key

    /// The part of the content this attempt prepares.
    public let phase: PreparationPhase

    fileprivate let attempt: UUID
}

/// A change of effective demand and the attempts this client no longer needs.
public struct ContentDemandChange<Key: Hashable & Sendable>: Sendable, Equatable {
    /// Effective demand before the change.
    public let previous: ContentDemand

    /// Effective demand after the change.
    public let current: ContentDemand

    /// Flags that became needed, including implied work.
    public var entered: ContentDemand { current.subtracting(previous) }

    /// Flags that stopped being needed.
    public var exited: ContentDemand { previous.subtracting(current) }

    /// Attempts invalidated by this change, in phase order.
    /// The owner cancels only their client waits, not resources shared with other clients.
    public let cancelled: [PreparationTicket<Key>]
}

/// Tracks demand and independent readiness before or after an item has a live node.
///
/// This value owns no task, callback, result, or shared resource. Its owner serializes
/// mutations, typically on the main actor, starts work within its budget, and cancels the
/// client waits returned by updates. Sending a ticket to a worker does not send this
/// mutable state or a node. No operation calls user code or suspends.
///
/// The key must include every input that makes a retained result stale: item revision,
/// measurement constraints, and relevant environment. Reset when those inputs change.
/// Leaving a range invalidates unneeded running attempts but retains ready results and
/// failures. Reentry uses retained results; failures require an explicit retry.
public struct ContentLifecycle<Key: Hashable & Sendable>: Sendable {
    /// The key all current attempts and retained results belong to.
    public private(set) var key: Key

    /// Effective work needed now, including display and visible implications.
    public private(set) var demand: ContentDemand

    /// Independent readiness; visible demand does not set any phase to ready.
    public private(set) var readiness = ContentReadiness()

    private var attempts: [PreparationPhase: PreparationTicket<Key>] = [:]

    /// Creates an item lifecycle without starting any work.
    public init(key: Key, demand: ContentDemand = []) {
        self.key = key
        self.demand = demand.requirements
    }

    /// Changes demand without starting work or dropping completed results.
    ///
    /// - Returns: Entered and exited flags and invalidated running attempts, or `nil` if
    ///   effective demand did not change. Cancel the returned client waits explicitly.
    @discardableResult
    public mutating func updateDemand(_ requested: ContentDemand) -> ContentDemandChange<Key>? {
        let next = requested.requirements
        guard next != demand else { return nil }

        let previous = demand
        demand = next
        var cancelled: [PreparationTicket<Key>] = []
        for phase in PreparationPhase.allCases where !next.requires(phase) {
            if let ticket = attempts.removeValue(forKey: phase) {
                readiness.set(.cancelled, for: phase)
                cancelled.append(ticket)
            }
        }
        return ContentDemandChange(previous: previous, current: next, cancelled: cancelled)
    }

    /// Claims one needed phase so the owner can schedule its work exactly once.
    ///
    /// A ready or running phase is never restarted. Failed phases stay failed unless
    /// `retrying` is true; cancelled phases may start again when needed. This does not
    /// wait for other phases: the resource owner enforces dependencies and queue limits.
    ///
    /// - Returns: A fresh ticket, or `nil` if this phase needs no new attempt.
    public mutating func begin(
        _ phase: PreparationPhase,
        retrying: Bool = false
    ) -> PreparationTicket<Key>? {
        guard demand.requires(phase) else { return nil }

        switch readiness[phase] {
        case .ready, .running: return nil
        case .failed where !retrying: return nil
        default: break
        }
        let ticket = PreparationTicket(key: key, phase: phase, attempt: UUID())
        attempts[phase] = ticket
        readiness.set(.running, for: phase)
        return ticket
    }

    /// Whether this ticket still identifies a running attempt of this lifecycle.
    public func isCurrent(_ ticket: PreparationTicket<Key>) -> Bool {
        attempts[ticket.phase] == ticket
    }

    /// Accepts a current completion and rejects a cancelled, repeated, or stale one.
    ///
    /// - Returns: Whether the completion was accepted. The owner may commit its result or
    ///   error only on `true`, on the same serialized executor without an intervening await.
    ///   This operation does not store resources or roll back work completed in a cache.
    @discardableResult
    public mutating func complete(
        _ ticket: PreparationTicket<Key>,
        with outcome: PreparationOutcome
    ) -> Bool {
        guard isCurrent(ticket) else { return false }

        attempts[ticket.phase] = nil
        let state: PreparationState
        switch outcome {
        case .ready: state = .ready
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        readiness.set(state, for: ticket.phase)
        return true
    }

    /// Invalidates one retained result or running attempt, as when memory must be released.
    ///
    /// The phase becomes idle and may be started again if still needed. The owner releases
    /// its resource and cancels the returned client wait; other phases remain unchanged.
    @discardableResult
    public mutating func release(_ phase: PreparationPhase) -> PreparationTicket<Key>? {
        let cancelled = attempts.removeValue(forKey: phase)
        readiness.set(.idle, for: phase)
        return cancelled
    }

    /// Replaces the key and invalidates every result and attempt, preserving demand.
    ///
    /// This also resets when the key is equal, allowing an explicit refresh. The owner
    /// drops its retained resources, cancels the returned client waits, and starts needed
    /// phases for the new key. Copies of this value are snapshots, not independent clients.
    @discardableResult
    public mutating func reset(for key: Key) -> [PreparationTicket<Key>] {
        let cancelled = PreparationPhase.allCases.compactMap { attempts[$0] }
        self.key = key
        attempts = [:]
        readiness = ContentReadiness()
        return cancelled
    }
}
