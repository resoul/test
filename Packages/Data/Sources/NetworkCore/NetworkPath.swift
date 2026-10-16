/// What the system says about the network the device is on right now.
///
/// It is a hint, not a promise: a path that is satisfied says the system has a route out, not that
/// a request will get through it — the server may be down, a captive portal may be in the way,
/// the Wi-Fi may be a cable that is not connected to anything. And a path that is not satisfied
/// is not a reason to refuse a request the app has been asked to make: the person may know better.
/// Use it to choose when to try again, and what to say while waiting, not to decide that
/// something cannot work.
public struct NetworkPath: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// The system has a route.
        case satisfied
        /// It has none.
        case unsatisfied
        /// It could have one if something were started — a VPN, a connection on demand.
        case requiresConnection
    }

    public var status: Status
    /// The route costs the person: cellular, or a personal hotspot.
    public var isExpensive: Bool
    /// The person has asked to use less data (Low Data Mode).
    public var isConstrained: Bool

    public init(status: Status, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// Whether the system has a route out.
    public var isReachable: Bool { status == .satisfied }
}

/// Tells what path the device is on, now and as it changes.
public protocol NetworkPathMonitoring: Sendable {
    /// The path now, and then each time it changes, until the stream is dropped or its iteration ends.
    ///
    /// Each stream observes on its own, and ending it ends that observation. A slow consumer gets
    /// the latest path and misses the ones in between, which is what a path is: a state, not
    /// events.
    func paths() -> AsyncStream<NetworkPath>
}
