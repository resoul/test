import Foundation

/// A download that can be taken up again where it broke off: the file the bytes so far are in, and
/// beside it a record of what the server said the bytes belong to.
///
/// The app chooses the file and keeps it between runs; the record is a second file next to it, named
/// like it with `.validators` added. To continue, the client asks the server for the rest of the
/// bytes (`Range`) **on condition that the thing is still the one it started** (`If-Range`, with
/// the `ETag` or `Last-Modified` of the first answer). If the thing changed meanwhile the server answers
/// with the whole of the new one, and the file starts over; no mixture of two versions is possible.
/// With no record, or a record without a validator that can be put in `If-Range`, the download
/// cannot be continued and starts over.
public struct PartialDownload: Sendable, Equatable {
    /// Where the bytes so far are.
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The record's place.
    public var validatorsFile: URL { URL(fileURLWithPath: file.path + ".validators") }

    /// How many bytes the file has; zero when there is no file.
    public var size: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// What the server said the bytes belong to, or `nil` when there is no record.
    public func validators() -> HTTPValidators? {
        guard let data = try? Data(contentsOf: validatorsFile) else { return nil }

        return try? JSONDecoder().decode(HTTPValidators.self, from: data)
    }

    /// Writes the record. A failure to write is not reported: the download then cannot be continued
    /// later, which is no worse than having no record.
    public func store(_ validators: HTTPValidators) {
        guard let data = try? JSONEncoder().encode(validators) else { return }

        try? data.write(to: validatorsFile, options: .atomic)
    }

    /// Removes the file and the record.
    public func discard() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: validatorsFile)
    }

    /// Removes the record only; for a download that has finished and moved its file away.
    public func discardRecord() {
        try? FileManager.default.removeItem(at: validatorsFile)
    }

    /// The headers that ask for the rest, or `nil` when the download cannot be continued: no bytes
    /// yet, no record, or no validator that `If-Range` accepts — a strong `ETag` (a weak one,
    /// `W/"…"`, is not allowed there) or else `Last-Modified`.
    public func resumeHeaders() -> HTTPHeaders? {
        let size = size
        guard size > 0, let validators = validators() else { return nil }

        let condition: String
        if let etag = validators.etag, !etag.hasPrefix("W/") {
            condition = etag
        } else if let modified = validators.lastModified {
            condition = modified
        } else {
            return nil
        }
        var headers = HTTPHeaders()
        headers["Range"] = "bytes=\(size)-"
        headers["If-Range"] = condition
        return headers
    }

    /// The first byte a `206` answer carries and the whole size of the thing, from its
    /// `Content-Range: bytes first-last/total`; `total` is `nil` when the server does not know it.
    /// A `416` answer says `bytes */total`, which has no first byte.
    public static func contentRange(of headers: HTTPHeaders) -> (first: Int64?, total: Int64?)? {
        guard let value = headers["Content-Range"] else { return nil }

        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }

        let range = text.dropFirst(6).split(separator: "/", maxSplits: 1).map(String.init)
        guard range.count == 2 else { return nil }

        let first = range[0].split(separator: "-").first.flatMap { Int64($0) }
        return (first, Int64(range[1]))
    }
}
