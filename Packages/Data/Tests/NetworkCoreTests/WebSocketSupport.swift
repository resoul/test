import Foundation
import NetworkCore
import os

let socketURL = URL(string: "wss://api.example.com/live")!

/// A connection the test drives by hand: it pushes what the "server" says and reads what the client
/// sent.
final class FakeConnection: WebSocketConnection, Sendable {
    enum Inbound: Sendable {
        case message(WebSocketMessage)
        case failure(WebSocketError)
    }

    enum PingBehavior: Sendable {
        case answer
        case neverAnswer
        case fail(WebSocketError)
    }

    private struct State {
        var inbox: [Inbound] = []
        var receiver: CheckedContinuation<Inbound, Never>?
        var pinger: CheckedContinuation<Void, Never>?
        var sent: [WebSocketMessage] = []
        var closes: [Int] = []
        var pings = 0
        var activeSends = 0
        var maxActiveSends = 0
        var pingBehavior: PingBehavior = .answer
        var sendDelay: Duration = .zero
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var sent: [WebSocketMessage] { state.withLock { $0.sent } }
    var closes: [Int] { state.withLock { $0.closes } }
    var isClosed: Bool { state.withLock { !$0.closes.isEmpty } }
    var pings: Int { state.withLock { $0.pings } }
    var maxActiveSends: Int { state.withLock { $0.maxActiveSends } }
    /// Messages the client has not read yet.
    var unread: Int { state.withLock { $0.inbox.count } }

    func setPingBehavior(_ behavior: PingBehavior) { state.withLock { $0.pingBehavior = behavior } }

    func setSendDelay(_ delay: Duration) { state.withLock { $0.sendDelay = delay } }

    func push(_ message: WebSocketMessage) { deliver(.message(message)) }

    func push(text: String) { push(.text(text)) }

    /// The "server" closes with a close frame, or the connection breaks.
    func fail(_ error: WebSocketError) { deliver(.failure(error)) }

    private func deliver(_ item: Inbound) {
        let receiver = state.withLock { state -> CheckedContinuation<Inbound, Never>? in
            if let waiting = state.receiver {
                state.receiver = nil
                return waiting
            }
            state.inbox.append(item)
            return nil
        }
        receiver?.resume(returning: item)
    }

    func send(_ message: WebSocketMessage) async throws(WebSocketError) {
        let delay = state.withLock { state -> Duration in
            state.activeSends += 1
            state.maxActiveSends = max(state.maxActiveSends, state.activeSends)
            return state.sendDelay
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        state.withLock {
            $0.sent.append(message)
            $0.activeSends -= 1
        }
    }

    func receive() async throws(WebSocketError) -> WebSocketMessage {
        let item: Inbound = await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Inbound? in
                if !state.inbox.isEmpty { return state.inbox.removeFirst() }
                if !state.closes.isEmpty { return .failure(.cancelled) }
                state.receiver = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        switch item {
        case .message(let message): return message
        case .failure(let error): throw error
        }
    }

    func ping() async throws(WebSocketError) {
        let behavior = state.withLock { state -> PingBehavior in
            state.pings += 1
            return state.pingBehavior
        }
        switch behavior {
        case .answer: return
        case .fail(let error): throw error
        case .neverAnswer:
            await withCheckedContinuation { continuation in
                let closed = state.withLock { state -> Bool in
                    if !state.closes.isEmpty { return true }
                    state.pinger = continuation
                    return false
                }
                if closed { continuation.resume() }
            }
            throw .cancelled
        }
    }

    func close(code: Int, reason: String?) {
        let (receiver, pinger) = state.withLock {
            state -> (CheckedContinuation<Inbound, Never>?, CheckedContinuation<Void, Never>?) in
            state.closes.append(code)
            defer {
                state.receiver = nil
                state.pinger = nil
            }
            return (state.receiver, state.pinger)
        }
        receiver?.resume(returning: .failure(.cancelled))
        pinger?.resume()
    }
}

/// Opens the connections a test gives it, in order, or fails as told.
final class FakeSocketTransport: WebSocketTransport, Sendable {
    enum Step: Sendable {
        case connection(FakeConnection)
        case failure(WebSocketError)
        /// Waits for `release`, then gives the connection: a handshake that takes its time.
        case slow(FakeConnection, Gate)
    }

    final class Gate: Sendable {
        private let opened = OSAllocatedUnfairLock(initialState: false)

        func open() { opened.withLock { $0 = true } }

        func wait() async {
            while !opened.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    private struct State {
        var steps: [Step]
        var requests: [HTTPRequest] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ steps: [Step]) {
        state = OSAllocatedUnfairLock(initialState: State(steps: steps))
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }

    var connectCount: Int { requests.count }

    func connect(_ request: HTTPRequest, maxMessageBytes: Int) async throws(WebSocketError)
        -> any WebSocketConnection
    {
        let step = state.withLock { state -> Step in
            state.requests.append(request)
            // The last step repeats, so a test that only cares about the first few need not pad.
            return state.steps.count > 1 ? state.steps.removeFirst() : state.steps[0]
        }
        switch step {
        case .connection(let connection): return connection
        case .failure(let error): throw error
        case .slow(let connection, let gate):
            await gate.wait()
            return connection
        }
    }
}

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(
        initialState: Date(timeIntervalSince1970: 1_000_000)
    )

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Waits of a second or more cost nothing and are recorded, which is enough for backoff; shorter
/// ones are real, which is what the heartbeat tests use.
final class Sleeps: Sendable {
    private let stored = OSAllocatedUnfairLock(initialState: [TimeInterval]())

    var delays: [TimeInterval] { stored.withLock { $0 } }

    func environment(clock: TestClock = TestClock()) -> NetworkEnvironment {
        NetworkEnvironment(
            now: { clock.now },
            sleep: { delay in
                if delay >= 1 {
                    self.stored.withLock { $0.append(delay) }
                    try Task.checkCancellation()
                    // A yield, so that a backoff that is instant does not starve other tasks.
                    await Task.yield()
                } else {
                    try await Task.sleep(for: .seconds(delay))
                }
            },
            random: { 0.5 }
        )
    }
}

func makeClient(
    _ transport: FakeSocketTransport,
    configuration: WebSocketConfiguration = WebSocketConfiguration(),
    authorizer: (any HTTPAuthorizer)? = nil,
    sleeps: Sleeps = Sleeps(),
    clock: TestClock = TestClock()
) -> WebSocketClient {
    WebSocketClient(
        request: HTTPRequest(.get, socketURL),
        transport: transport,
        configuration: configuration,
        authorizer: authorizer,
        environment: sleeps.environment(clock: clock)
    )
}

/// Polls until `condition` holds or five seconds pass.
func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

/// The next `count` events.
func take(_ count: Int, from client: WebSocketClient) async -> [WebSocketEvent] {
    var events: [WebSocketEvent] = []
    while events.count < count, let event = await client.nextEvent() { events.append(event) }
    return events
}

func isMessage(_ event: WebSocketEvent?, _ text: String) -> Bool {
    if case .message(.text(let received))? = event { return received == text }
    return false
}
