import Foundation
import NetworkCore
import os

/// A server for the demo and its tests, in memory: it answers HTTP requests and WebSocket
/// connections without a network, through the same transport protocols the real clients use.
///
/// It keeps a list of items and a numbered history of the changes made to it, and speaks the protocol
/// of ``Snapshot``, ``ServerMessage`` and ``Subscribe``. Every change — by a client's request or by
/// the `external` methods, which stand for another user — gets the next sequence number and is
/// pushed to the subscribed sockets. `POST /items` honours `Idempotency-Key`: the same key
/// returns the same item and creates no second one.
///
/// The `simulate` and `set` methods bring about what a real network does — a dropped connection,
/// no connection at all, a slow answer, a lost reply — so that a screen can be seen to cope.
public actor DemoServer: HTTPTransport, WebSocketTransport {
    private var items: [String: Item] = [:]
    private var seq = 0
    private var history: [ServerMessage] = []
    private let retention: Int
    private var created: [String: Item] = [:]
    private var nextNumber = 1

    private var isOnline = true
    private var holdsSnapshots = false
    private var sockets: [UUID: DemoSocket] = [:]
    private var subscribed: Set<UUID> = []
    private var failuresBeforePost: [Int] = []
    private var nextPostReplyIsLost = false

    /// How many snapshots were asked for, and how many posts were handled; for tests that count.
    public private(set) var snapshotRequests = 0
    public private(set) var postsHandled = 0

    /// - Parameter retention: How many of the latest changes are kept to replay to a client that
    ///   reconnects. A client further behind is told to fetch a snapshot.
    public init(items: [Item] = [], retention: Int = 100) {
        self.retention = retention
        for item in items {
            self.items[item.id] = item
            seq = max(seq, item.revision)
        }
        nextNumber = items.count + 1
    }

    // MARK: Things that happen to the server

    /// Another user adds or changes an item.
    @discardableResult
    public func externalUpsert(id: String? = nil, title: String) -> Item {
        let item = Item(id: id ?? makeID(), title: title, revision: 0)
        return commit(item)
    }

    /// Another user deletes an item.
    public func externalDelete(id: String) {
        guard items.removeValue(forKey: id) != nil else { return }

        seq += 1
        record(.delete(seq: seq, id: id))
    }

    /// Breaks every socket without a close, as a lost connection does.
    public func simulateDroppedConnections() {
        for socket in sockets.values { socket.fail(.transport(Self.lost)) }
        sockets.removeAll()
        subscribed.removeAll()
    }

    /// No requests get through, and every socket is broken, until it is set back.
    public func setOnline(_ online: Bool) {
        isOnline = online
        if !online { simulateDroppedConnections() }
    }

    /// While held, an answer to a snapshot request is built at once but delivered only when the hold
    /// ends: it arrives old, as a slow reply does.
    public func setHoldingSnapshots(_ holding: Bool) { holdsSnapshots = holding }

    /// The next `POST`s fail with these statuses, one each, before they do anything.
    public func failNextPosts(with statuses: [Int]) { failuresBeforePost = statuses }

    /// The next `POST` is carried out but its reply is lost, as when the connection breaks after
    /// the server has acted.
    public func loseNextPostReply() { nextPostReplyIsLost = true }

    /// What the server has, as a client would be told.
    public var snapshot: Snapshot {
        Snapshot(cursor: seq, items: items.values.sorted { $0.id < $1.id })
    }

    public var socketCount: Int { sockets.count }

    // MARK: HTTP

    public func send(_ request: HTTPRequest, maxResponseBytes: Int?) async throws(HTTPError)
        -> HTTPResponse
    {
        guard isOnline else { throw .transport(Self.unreachable) }

        let path = request.url.path
        switch (request.method, path) {
        case (.get, "/items"):
            snapshotRequests += 1
            let body = try Self.encode(snapshot)
            // The answer is fixed now; waiting does not change it.
            while holdsSnapshots {
                if Task.isCancelled { throw .cancelled }
                try? await Task.sleep(for: .milliseconds(2))
            }
            if Task.isCancelled { throw .cancelled }
            guard isOnline else { throw .transport(Self.unreachable) }

            return HTTPResponse(status: 200, body: body, url: request.url)
        case (.post, "/items"):
            return try handlePost(request)
        default:
            return HTTPResponse(status: 404, url: request.url)
        }
    }

    private func handlePost(_ request: HTTPRequest) throws(HTTPError) -> HTTPResponse {
        postsHandled += 1
        if !failuresBeforePost.isEmpty {
            return HTTPResponse(status: failuresBeforePost.removeFirst(), url: request.url)
        }
        guard let body = request.body, let new = try? JSONDecoder().decode(NewItem.self, from: body)
        else { return HTTPResponse(status: 400, url: request.url) }

        let item: Item
        if let key = request.headers["Idempotency-Key"], let earlier = created[key] {
            item = earlier
        } else {
            item = commit(Item(id: makeID(), title: new.title, revision: 0))
            if let key = request.headers["Idempotency-Key"] { created[key] = item }
        }
        if nextPostReplyIsLost {
            nextPostReplyIsLost = false
            throw .transport(Self.lost)
        }
        return HTTPResponse(status: 201, body: try Self.encode(item), url: request.url)
    }

    // MARK: Changes

    private func makeID() -> String {
        defer { nextNumber += 1 }
        return "item-\(nextNumber)"
    }

    /// Stores `item` with the next revision and tells the subscribers.
    private func commit(_ item: Item) -> Item {
        seq += 1
        var stored = item
        stored.revision = seq
        items[stored.id] = stored
        record(.upsert(seq: seq, stored))
        return stored
    }

    private func record(_ message: ServerMessage) {
        history.append(message)
        if history.count > retention { history.removeFirst(history.count - retention) }
        guard let text = Self.text(message) else { return }

        for id in subscribed { sockets[id]?.push(.text(text)) }
    }

    // MARK: WebSocket

    public func connect(_ request: HTTPRequest, maxMessageBytes: Int) async throws(WebSocketError)
        -> any WebSocketConnection
    {
        guard isOnline else { throw .transport(Self.unreachable) }

        let id = UUID()
        let socket = DemoSocket(server: self, id: id)
        sockets[id] = socket
        return socket
    }

    fileprivate func receive(_ message: WebSocketMessage, from id: UUID) {
        guard case .text(let text) = message,
            let subscribe = try? JSONDecoder().decode(Subscribe.self, from: Data(text.utf8)),
            let socket = sockets[id]
        else { return }

        let oldestKept = history.first?.seq ?? (seq + 1)
        if subscribe.since + 1 < oldestKept {
            // What the client missed is no longer kept.
            if let text = Self.text(.resync) { socket.push(.text(text)) }
        } else {
            for message in history where (message.seq ?? 0) > subscribe.since {
                if let text = Self.text(message) { socket.push(.text(text)) }
            }
        }
        subscribed.insert(id)
    }

    fileprivate func closed(_ id: UUID) {
        sockets[id] = nil
        subscribed.remove(id)
    }

    // MARK: Encoding

    private static func encode<Value: Encodable>(_ value: Value) throws(HTTPError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .encoding(underlying: error)
        }
    }

    private static func text(_ message: ServerMessage) -> String? {
        (try? JSONEncoder().encode(message)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static var lost: TransportFailure {
        TransportFailure(kind: .connectionLost, underlying: URLError(.networkConnectionLost))
    }

    private static var unreachable: TransportFailure {
        TransportFailure(kind: .notConnected, underlying: URLError(.notConnectedToInternet))
    }
}

/// The client's end of a socket to a ``DemoServer``.
final class DemoSocket: WebSocketConnection, Sendable {
    private enum Inbound: Sendable {
        case message(WebSocketMessage)
        case failure(WebSocketError)
    }

    private struct State {
        var inbox: [Inbound] = []
        var receiver: CheckedContinuation<Inbound, Never>?
        var isClosed = false
    }

    private let server: DemoServer
    private let id: UUID
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(server: DemoServer, id: UUID) {
        self.server = server
        self.id = id
    }

    /// The server speaks.
    func push(_ message: WebSocketMessage) { deliver(.message(message)) }

    /// The connection breaks.
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
        if state.withLock({ $0.isClosed }) { throw .notConnected }

        await server.receive(message, from: id)
    }

    func receive() async throws(WebSocketError) -> WebSocketMessage {
        let item: Inbound = await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Inbound? in
                if !state.inbox.isEmpty { return state.inbox.removeFirst() }
                if state.isClosed { return .failure(.cancelled) }
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
        if state.withLock({ $0.isClosed }) { throw .notConnected }
    }

    func close(code: Int, reason: String?) {
        let receiver = state.withLock { state -> CheckedContinuation<Inbound, Never>? in
            state.isClosed = true
            defer { state.receiver = nil }
            return state.receiver
        }
        receiver?.resume(returning: .failure(.cancelled))
        let id = id
        let server = server
        Task { await server.closed(id) }
    }
}
