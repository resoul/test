import Foundation

/// The whole list as the server has it, with the point in the server's history it is taken at.
///
/// `cursor` is the sequence number of the last change the snapshot contains. A client that holds a
/// snapshot asks for the changes after its cursor, so none falls between the snapshot and the live
/// stream.
public struct Snapshot: Codable, Sendable, Equatable {
    public var cursor: Int
    public var items: [Item]

    public init(cursor: Int, items: [Item]) {
        self.cursor = cursor
        self.items = items
    }
}

/// What the server says over the socket.
///
/// `event` carries one change, numbered `seq`, which counts without gaps: a client that sees
/// `seq` jump has missed something. `resync` says the changes the client asked for are no longer
/// kept, so it must fetch a snapshot.
public struct ServerMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case event
        case resync
    }

    public enum Change: String, Codable, Sendable {
        case upsert
        case delete
    }

    public var type: Kind
    public var seq: Int?
    public var change: Change?
    public var item: Item?
    public var id: String?

    public static func upsert(seq: Int, _ item: Item) -> ServerMessage {
        ServerMessage(type: .event, seq: seq, change: .upsert, item: item, id: nil)
    }

    public static func delete(seq: Int, id: String) -> ServerMessage {
        ServerMessage(type: .event, seq: seq, change: .delete, item: nil, id: id)
    }

    public static let resync = ServerMessage(
        type: .resync,
        seq: nil,
        change: nil,
        item: nil,
        id: nil
    )
}

/// What a client says over the socket: where in the history it is, so that the server can send
/// what it missed.
public struct Subscribe: Codable, Sendable, Equatable {
    public var type = "subscribe"
    public var since: Int

    public init(since: Int) {
        self.since = since
    }
}

struct NewItem: Codable, Sendable {
    var title: String
}
