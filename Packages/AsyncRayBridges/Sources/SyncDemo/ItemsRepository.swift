import AsyncRay
import DataAsyncRay
import Foundation
import GRDB
import NetworkCore
import StorageCore
import StorageGRDB

/// Keeps a list of items on this device in step with a server: the database holds the list, HTTP
/// fetches it, a socket keeps it current, and a screen only ever reads the database.
///
/// **One source of truth.** HTTP and the socket write to the database, never to a screen. A screen
/// watches the database through ``rows(sortedBy:)`` and sees a consistent snapshot after every
/// commit, so what it shows always agrees with what was stored, and a screen opened later, or a
/// second window, shows the same.
///
/// **Snapshot and live changes.** A snapshot from HTTP carries a cursor — the number of the last
/// change it contains. Changes from the socket are numbered, without gaps. The repository keeps the
/// cursor in the same transaction as the change it belongs to, so the two never disagree, and
/// applies a change only if its number is exactly the next one: an older one is a repeat and is
/// ignored, a later one means something was missed, and a snapshot is fetched. Each time the socket
/// connects it says where it is, and the server sends what it missed. A snapshot older than what
/// the database already holds is discarded, so a slow answer never undoes a newer change.
///
/// **Signing out.** ``signOut()`` leaves nothing of the account and nothing that can come back. The
/// database holds an epoch that the sign-out raises in the same transaction that empties it, and
/// every write that was waiting on the network checks the epoch it started under: an answer that
/// arrives late finds a different epoch and writes nothing.
///
/// Ownership: the repository holds the socket's event loop and any refresh in progress, and cancels
/// both in ``stop()`` and ``signOut()``; it does not depend on being released to stop. Several
/// models, one per window, share one repository.
public actor ItemsRepository {
    /// The folder of the file store that holds attachments, one folder per item.
    static let attachmentsFolder = "attachments"

    private let database: DatabaseStore
    private let http: HTTPClient
    private let socket: WebSocketClient
    private let files: any FileStore
    private let itemsURL: URL
    private var eventLoop: Task<Void, Never>?
    private var refreshing: Task<Void, any Error>?

    /// The schema the repository needs. Pass it to ``DatabaseStore/open(_:migrations:)``.
    public static let migrations: [DatabaseMigration] = [
        DatabaseMigration("createItems") { db in
            try db.create(table: "item") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("attachmentName", .text)
                table.column("attachmentSize", .integer)
            }
            try db.create(table: "syncState") { table in
                table.column("id", .integer).primaryKey().check { $0 == 1 }
                table.column("cursor", .integer).notNull()
                table.column("epoch", .integer).notNull()
                // Whether a snapshot has been stored for the current account: until it has, the
                // cursor means nothing, and there is nothing to ask the server to continue from.
                table.column("synced", .integer).notNull()
            }
            try db.execute(
                sql: "INSERT INTO syncState (id, cursor, epoch, synced) VALUES (1, 0, 0, 0)"
            )
        }
    ]

    /// - Parameters:
    ///   - database: Opened with ``migrations``.
    ///   - http: A client whose transport reaches the server. Give it a retry policy to have reads
    ///     repeated; an `add` carries an idempotency key, so a repeat is safe.
    ///   - socket: A client for the server's live channel, not yet connected.
    ///   - files: Where attachments are kept.
    ///   - itemsURL: The address of the list on the server.
    public init(
        database: DatabaseStore,
        http: HTTPClient,
        socket: WebSocketClient,
        files: any FileStore,
        itemsURL: URL
    ) {
        self.database = database
        self.http = http
        self.socket = socket
        self.files = files
        self.itemsURL = itemsURL
    }

    // MARK: Reading

    /// The list in the given order, now and after every commit that changes it.
    ///
    /// A failure of the database arrives as a failure element, not as an empty list. The stream
    /// belongs to its subscription: cancelling the subscription ends the observation.
    public nonisolated func rows(sortedBy sort: ItemSort) -> AsyncRay<
        Result<[ItemRow], DatabaseStoreError>
    > {
        database.observeRay { db in try Self.fetchRows(db, sort: sort) }
    }

    /// The socket's state, now and on each change.
    public nonisolated var connection: AsyncRay<WebSocketState> { socket.statesRay }

    private static func fetchRows(_ db: Database, sort: ItemSort) throws -> [ItemRow] {
        let order =
            switch sort {
            case .title: "title COLLATE NOCASE, id"
            case .newest: "revision DESC, id"
            }
        let sql =
            "SELECT id, title, revision, attachmentName, attachmentSize FROM item ORDER BY \(order)"
        return try Row.fetchAll(db, sql: sql).map { row in
            let name: String? = row["attachmentName"]
            let size: Int? = row["attachmentSize"]
            return ItemRow(
                id: row["id"],
                title: row["title"],
                revision: row["revision"],
                attachment: name.map { Attachment(name: $0, size: size ?? 0) }
            )
        }
    }

    // MARK: Running

    /// Connects the socket and starts following it. Safe to call again: it does nothing while
    /// running.
    public func start() {
        guard eventLoop == nil else { return }

        let socket = socket
        eventLoop = Task { [weak self] in
            await socket.connect()
            while let event = await socket.nextEvent() {
                // Held weakly between events, so that the loop does not keep the repository alive.
                guard let self else { return }

                await self.handle(event)
            }
        }
    }

    /// Stops following the socket and closes it, and cancels a refresh in progress. What is stored
    /// stays. ``start()`` runs it again.
    public func stop() async {
        eventLoop?.cancel()
        eventLoop = nil
        refreshing?.cancel()
        refreshing = nil
        await socket.close()
    }

    // MARK: The socket

    private func handle(_ event: WebSocketEvent) async {
        switch event {
        case .connected:
            // Say where this device is, so that the server sends what it missed. Before the first
            // snapshot there is no such place, so the snapshot comes first. A fetch that is already
            // running is waited for before asking whether one is still needed: asking first would
            // see "none yet", and the fetch could finish before this one started, making a second.
            // If the send fails the connection is already lost
            // and the next one will say it again.
            if let running = refreshing { try? await Self.wait(for: running) }
            if let state = try? await currentState(), !state.synced { try? await refresh() }
            let cursor = (try? await currentState().cursor) ?? 0
            if let data = try? JSONEncoder().encode(Subscribe(since: cursor)) {
                try? await socket.send(.text(String(decoding: data, as: UTF8.self)))
            }
        case .message(.text(let text)):
            guard let message = try? JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
            else { return }

            switch message.type {
            case .resync: try? await refresh()
            case .event: await apply(message)
            }
        case .message(.binary), .disconnected:
            break
        case .resyncRequired:
            try? await refresh()
        }
    }

    private enum Applied {
        case applied
        case repeated
        case missedSomething
        case outdated
    }

    private func apply(_ message: ServerMessage) async {
        guard let seq = message.seq else { return }

        let outcome: Applied
        do {
            let epoch = try await currentState().epoch
            outcome = try await database.write { db in
                let state = try Self.state(db)
                guard state.epoch == epoch else { return .outdated }
                if seq <= state.cursor { return .repeated }
                if seq > state.cursor + 1 { return .missedSomething }

                switch message.change {
                case .upsert?:
                    if let item = message.item { try Self.upsert(item, in: db) }
                case .delete?:
                    if let id = message.id {
                        try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id])
                    }
                case nil:
                    break
                }
                // The change and its number are stored together or not at all.
                try db.execute(sql: "UPDATE syncState SET cursor = ?", arguments: [seq])
                return .applied
            }
        } catch {
            return
        }
        if case .missedSomething = outcome { try? await refresh() }
        if message.change == .delete, case .applied = outcome, let id = message.id {
            _ = try? await files.remove(attachmentFolder(for: id))
        }
    }

    // MARK: Fetching

    /// Fetches the list and makes the database agree with it.
    ///
    /// One refresh runs at a time: a call while another is in progress waits for it and shares its
    /// result. Cancelling the calling task cancels the refresh for everyone waiting on it.
    ///
    /// - Throws: ``HTTPError`` when the server cannot be reached or refuses; `CancellationError`
    ///   when cancelled, which a screen should not show as a failure; the database's errors.
    public func refresh() async throws {
        if let running = refreshing {
            try await Self.wait(for: running)
            return
        }
        let task = Task { try await self.performRefresh() }
        refreshing = task
        do {
            try await Self.wait(for: task)
            refreshing = nil
        } catch {
            refreshing = nil
            throw error
        }
    }

    private static func wait(for task: Task<Void, any Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// One refresh, without the bookkeeping of ``refresh()``: the fetch and the write under the
    /// epoch it started in. Separate so that a test can run it where ``signOut()``'s cancellation
    /// does not reach it, which is what the epoch check is for.
    func performRefresh() async throws {
        let epoch = try await currentState().epoch
        let snapshot = try await http.send(HTTPRequest(.get, itemsURL), as: Snapshot.self)
        try Task.checkCancellation()

        let removed: [String] = try await database.write { db in
            let state = try Self.state(db)
            // The account was signed out meanwhile, or the answer is older than what is stored.
            guard state.epoch == epoch, snapshot.cursor >= state.cursor else { return [] }

            let attachments = try Row.fetchAll(
                db,
                sql:
                    "SELECT id, attachmentName, attachmentSize FROM item WHERE attachmentName IS NOT NULL"
            )
            var kept: [String: (String, Int)] = [:]
            for row in attachments {
                kept[row["id"]] = (row["attachmentName"], row["attachmentSize"])
            }

            let before = try String.fetchAll(db, sql: "SELECT id FROM item")
            try db.execute(sql: "DELETE FROM item")
            for item in snapshot.items {
                try db.execute(
                    sql: """
                        INSERT INTO item (id, title, revision, attachmentName, attachmentSize)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        item.id, item.title, item.revision, kept[item.id]?.0, kept[item.id]?.1,
                    ]
                )
            }
            try db.execute(
                sql: "UPDATE syncState SET cursor = ?, synced = 1",
                arguments: [snapshot.cursor]
            )
            let present = Set(snapshot.items.map(\.id))
            return before.filter { !present.contains($0) && kept[$0] != nil }
        }
        for id in removed { _ = try? await files.remove(attachmentFolder(for: id)) }
    }

    // MARK: Changes made here

    /// Adds an item on the server and in the database, and returns it.
    ///
    /// The request carries an idempotency key, so a client configured to repeat requests does not
    /// make two items when a reply is lost.
    public func add(title: String) async throws -> Item {
        let epoch = try await currentState().epoch
        var request = try HTTPRequest.json(.post, itemsURL, body: NewItem(title: title))
        request.headers["Idempotency-Key"] = UUID().uuidString
        let item = try await http.send(request, as: Item.self)

        try await database.write { db in
            guard try Self.state(db).epoch == epoch else { return }

            try Self.upsert(item, in: db)
        }
        return item
    }

    /// Keeps `data` on this device as an attachment of the item. The server does not see it.
    ///
    /// - Throws: ``FileError`` from the file store, including for a `name` that is not an
    ///   acceptable file name.
    public func attach(name: String, data: Data, to id: String) async throws {
        let path = try attachmentFolder(for: id).appending(name)
        let epoch = try await currentState().epoch
        try await files.write(data, to: path)

        let stored: Bool = try await database.write { db in
            guard try Self.state(db).epoch == epoch else { return false }

            try db.execute(
                sql: "UPDATE item SET attachmentName = ?, attachmentSize = ? WHERE id = ?",
                arguments: [name, data.count, id]
            )
            return db.changesCount > 0
        }
        // The account was signed out, or the item is gone: the file has no owner any more.
        if !stored { _ = try? await files.remove(path) }
    }

    /// The contents of an item's attachment.
    public func attachment(of id: String, named name: String) async throws -> Data {
        try await files.read(attachmentFolder(for: id).appending(name))
    }

    // MARK: Signing out

    /// Ends the account on this device: the socket and any refresh are stopped, the database is
    /// emptied and its epoch raised in one transaction, and the attachments are deleted.
    ///
    /// What was in flight cannot bring anything back: a request that returns later finds the
    /// epoch changed. The repository can be started again for the next account.
    public func signOut() async throws {
        eventLoop?.cancel()
        eventLoop = nil
        refreshing?.cancel()
        refreshing = nil
        try await database.write { db in
            try db.execute(sql: "DELETE FROM item")
            try db.execute(sql: "UPDATE syncState SET cursor = 0, synced = 0, epoch = epoch + 1")
        }
        await socket.close()
        if let root = try? FilePath(Self.attachmentsFolder) { _ = try? await files.remove(root) }
    }

    // MARK: Storage helpers

    /// What the database says about the sync: where it is in the server's history, and which
    /// account's data it holds.
    func currentState() async throws -> (cursor: Int, epoch: Int, synced: Bool) {
        try await database.read { db in try Self.state(db) }
    }

    private static func state(_ db: Database) throws -> (cursor: Int, epoch: Int, synced: Bool) {
        let row = try Row.fetchOne(db, sql: "SELECT cursor, epoch, synced FROM syncState")
        let synced: Int = row?["synced"] ?? 0
        return (row?["cursor"] ?? 0, row?["epoch"] ?? 0, synced != 0)
    }

    /// Stores `item` unless the database holds the same item at the same or a later revision, and
    /// keeps what this device attached to it.
    private static func upsert(_ item: Item, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO item (id, title, revision) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, revision = excluded.revision
                WHERE excluded.revision > item.revision
                """,
            arguments: [item.id, item.title, item.revision]
        )
    }

    private func attachmentFolder(for id: String) throws -> FilePath {
        try FilePath(Self.attachmentsFolder).appending(id)
    }
}
