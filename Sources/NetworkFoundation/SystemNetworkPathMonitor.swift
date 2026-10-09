import Foundation
import Network
import NetworkCore

/// A ``NetworkPathMonitoring`` over the system's `NWPathMonitor`.
///
/// It holds no state: each call of ``paths()`` makes a monitor of its own, starts it on a queue of
/// its own, and cancels it when the stream ends.
public struct SystemNetworkPathMonitor: NetworkPathMonitoring {
    public init() {}

    public func paths() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: NetworkPath.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            continuation.yield(Self.map(path))
        }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "network-path-monitor"))
        return stream
    }

    static func map(_ path: NWPath) -> NetworkPath {
        let status: NetworkPath.Status
        switch path.status {
        case .satisfied: status = .satisfied
        case .unsatisfied: status = .unsatisfied
        case .requiresConnection: status = .requiresConnection
        @unknown default: status = .unsatisfied
        }
        return NetworkPath(
            status: status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
