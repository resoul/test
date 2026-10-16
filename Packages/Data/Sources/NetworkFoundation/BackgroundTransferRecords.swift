import Foundation
import NetworkCore

/// What a background transfer carries in its task description: the system keeps the text with the
/// task across the app's endings, so after a relaunch the task still says whose it is and where its
/// file goes. Nothing about a transfer is held in memory and nowhere else.
struct BackgroundTransferLabel: Codable, Equatable {
    var id: String
    var kind: String
    /// A download's destination, relative to the transfers' directory.
    var path: String?

    init(id: BackgroundTransferID, kind: BackgroundTransferKind, path: String? = nil) {
        self.id = id.rawValue
        self.kind = kind.rawValue
        self.path = path
    }

    /// The label of `task`; `nil` for a task that is not one of ours, which is left alone.
    init?(_ task: URLSessionTask) {
        guard let text = task.taskDescription, let data = text.data(using: .utf8),
            let label = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }

        self = label
    }

    var text: String {
        String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }

    var transferID: BackgroundTransferID { BackgroundTransferID(id) }
    var transferKind: BackgroundTransferKind { BackgroundTransferKind(rawValue: kind) ?? .download }
}

/// An outcome as it is written to disk. The file is kept relative to the directory, because the
/// directory's absolute path can change between launches (an app's container is moved by an update).
struct BackgroundTransferRecord: Codable {
    var id: String
    var kind: String
    var status: Int?
    var headers: [[String]]
    var body: Data
    var file: String?
    var failureKind: String?
    var failureMessage: String?
    /// When it was written, to give outcomes back in the order they arrived.
    var finishedAt: Double

    init(_ outcome: BackgroundTransferOutcome, relativeFile: String?, at time: Date = Date()) {
        id = outcome.id.rawValue
        kind = outcome.kind.rawValue
        status = outcome.status
        headers = outcome.headers.all.map { [$0.name, $0.value] }
        body = outcome.body
        file = relativeFile
        failureKind = outcome.failure?.kind.rawValue
        failureMessage = outcome.failure?.message
        finishedAt = time.timeIntervalSince1970
    }

    func outcome(in directory: URL) -> BackgroundTransferOutcome {
        var fields = HTTPHeaders()
        for pair in headers where pair.count == 2 { fields.add(pair[1], for: pair[0]) }
        let failure = failureKind.map {
            BackgroundTransferOutcome.Failure(
                kind: .init(rawValue: $0) ?? .other,
                message: failureMessage ?? ""
            )
        }
        return BackgroundTransferOutcome(
            id: BackgroundTransferID(id),
            kind: BackgroundTransferKind(rawValue: kind) ?? .download,
            status: status,
            headers: fields,
            body: body,
            file: file.map { directory.appendingPathComponent($0) },
            failure: failure
        )
    }
}

/// The outcomes that have arrived and not been acknowledged, one small file each.
struct BackgroundTransferRecords: Sendable {
    /// The folder name inside the transfers' directory; a download may not be put there.
    static let folder = ".background-transfers"

    let directory: URL

    private var folderURL: URL { directory.appendingPathComponent(Self.folder, isDirectory: true) }

    private func file(for id: BackgroundTransferID) -> URL {
        // The name is encoded so that any id is a safe file name.
        let name =
            id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "transfer"
        return folderURL.appendingPathComponent(name + ".json")
    }

    func contains(_ id: BackgroundTransferID) -> Bool {
        FileManager.default.fileExists(atPath: file(for: id).path)
    }

    func write(_ record: BackgroundTransferRecord) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: file(for: BackgroundTransferID(record.id)), options: .atomic)
    }

    func remove(_ id: BackgroundTransferID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Every record, the oldest first. A file that does not read is skipped, not fatal: one bad
    /// record must not hide the others.
    func all() -> [BackgroundTransferRecord] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil
            )) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap {
                    try? JSONDecoder().decode(BackgroundTransferRecord.self, from: $0)
                }
            }
            .sorted { $0.finishedAt < $1.finishedAt }
    }
}

/// A download's `path`, checked, against the directory it is relative to.
enum BackgroundDestination {
    /// - Throws: ``HTTPError/invalidRequest(_:)`` for a path that is empty, absolute, or leaves the
    ///   directory (a `..` anywhere), or that points into the folder the records live in.
    static func resolve(_ path: String, in directory: URL) throws(HTTPError) -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(""), !parts.contains("."),
            !parts.contains(".."), parts.first != BackgroundTransferRecords.folder
        else { throw .invalidRequest("\"\(path)\" is not a path inside the transfers' directory") }

        return directory.appendingPathComponent(path)
    }
}
