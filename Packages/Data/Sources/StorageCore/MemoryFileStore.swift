import Foundation

/// A ``FileStore`` that keeps files in memory, for tests and previews. Nothing survives it.
///
/// It follows the same rules as a store on disk — paths, replacing, moving, listing — except
/// that it has no size limit and its modification dates come from the clock it is given.
public actor MemoryFileStore: FileStore {
    private var files: [FilePath: (data: Data, modified: Date)] = [:]
    private let now: @Sendable () -> Date

    /// - Parameter now: The clock that stamps modification dates.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func read(_ path: FilePath) throws(FileError) -> Data {
        if let file = files[path] { return file.data }
        if isDirectory(path) { throw .wrongKind(path) }
        throw .notFound(path)
    }

    public func write(_ data: Data, to path: FilePath) throws(FileError) {
        if isDirectory(path) { throw .wrongKind(path) }
        if hasFileAbove(path) { throw .wrongKind(path) }
        files[path] = (data, now())
    }

    public func importFile(at url: URL, to path: FilePath) throws(FileError) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .failed(path: nil, reason: error.localizedDescription)
        }
        try write(data, to: path)
    }

    public func metadata(of path: FilePath) -> FileMetadata? {
        if let file = files[path] {
            return FileMetadata(
                isDirectory: false,
                size: Int64(file.data.count),
                modificationDate: file.modified
            )
        }
        return isDirectory(path)
            ? FileMetadata(isDirectory: true, size: 0, modificationDate: nil) : nil
    }

    public func list(_ directory: FilePath?) throws(FileError) -> [FileEntry] {
        if let directory, files[directory] != nil { throw .wrongKind(directory) }

        let depth = directory?.components.count ?? 0
        var seen: Set<FilePath> = []
        var entries: [FileEntry] = []
        for path in files.keys where isInside(path, directory) {
            let childComponents = Array(path.components.prefix(depth + 1))
            guard let child = try? FilePath(childComponents.joined(separator: "/")),
                seen.insert(child).inserted,
                let metadata = metadata(of: child)
            else { continue }

            entries.append(FileEntry(path: child, metadata: metadata))
        }
        return entries.sorted { $0.path < $1.path }
    }

    @discardableResult
    public func remove(_ path: FilePath) -> Bool {
        let doomed = files.keys.filter { $0 == path || isInside($0, path) }
        for key in doomed { files[key] = nil }
        return !doomed.isEmpty
    }

    public func move(_ source: FilePath, to destination: FilePath, replacing: Bool)
        throws(FileError)
    {
        let moving = files.keys.filter { $0 == source || isInside($0, source) }
        if moving.isEmpty { throw .notFound(source) }
        if destination == source || isInside(destination, source) {
            throw .invalidPath("\(source) cannot be moved into itself")
        }
        if hasFileAbove(destination) { throw .wrongKind(destination) }
        if metadata(of: destination) != nil {
            guard replacing else { throw .alreadyExists(destination) }
            guard files[destination] != nil, files[source] != nil else {
                // Replacing a directory by a directory, or mixing kinds, is not supported.
                throw .wrongKind(destination)
            }
        }
        for old in moving {
            let rest = Array(old.components.dropFirst(source.components.count))
            let new = try destination.appendingComponents(rest)
            files[new] = files[old]
            files[old] = nil
        }
    }

    private func isDirectory(_ path: FilePath) -> Bool {
        files.keys.contains { isInside($0, path) }
    }

    /// Whether `path` is strictly below `directory`; the root (`nil`) holds everything.
    private func isInside(_ path: FilePath, _ directory: FilePath?) -> Bool {
        guard let directory else { return true }

        return path.components.count > directory.components.count
            && Array(path.components.prefix(directory.components.count)) == directory.components
    }

    /// Whether a name above `path` is a file, which would stop a file being created below it.
    private func hasFileAbove(_ path: FilePath) -> Bool {
        var current = path.parent
        while let candidate = current {
            if files[candidate] != nil { return true }
            current = candidate.parent
        }
        return false
    }
}

extension FilePath {
    fileprivate func appendingComponents(_ names: [String]) throws(FileError) -> FilePath {
        var result = self
        for name in names { result = try result.appending(name) }
        return result
    }
}
