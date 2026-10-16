/// A location inside a file store: a relative path made of plain names.
///
/// A path cannot be empty or absolute, and none of its names can be empty, `.` or `..`, start
/// with a dot, or contain a slash or a NUL character. Names that start with a dot are left to the
/// store, which uses them for its own temporary files. Because a path can only descend, no
/// operation that takes one can leave the store's root.
public struct FilePath: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The names from the root down to this location; never empty.
    public let components: [String]

    /// Creates a path from slash-separated text such as `"documents/report.pdf"`.
    ///
    /// - Throws: ``FileError/invalidPath(_:)`` with the reason the text is not acceptable.
    public init(_ text: String) throws(FileError) {
        if text.isEmpty { throw .invalidPath("the path is empty") }
        if text.hasPrefix("/") { throw .invalidPath("\(text) is absolute") }

        let names = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for name in names { try Self.validate(name, in: text) }
        components = names
    }

    private init(components: [String]) {
        self.components = components
    }

    /// The path of a child named `name` inside this location.
    ///
    /// - Throws: ``FileError/invalidPath(_:)`` when `name` is not a single acceptable name.
    public func appending(_ name: String) throws(FileError) -> FilePath {
        try Self.validate(name, in: "\(self)/\(name)")
        return FilePath(components: components + [name])
    }

    /// The last name: the file's or directory's own name.
    public var name: String { components[components.count - 1] }

    /// The directory that holds this location, or `nil` when it is directly in the root.
    public var parent: FilePath? {
        components.count > 1 ? FilePath(components: Array(components.dropLast())) : nil
    }

    public var description: String { components.joined(separator: "/") }

    public static func < (lhs: FilePath, rhs: FilePath) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    private static func validate(_ name: String, in text: String) throws(FileError) {
        if name.isEmpty { throw .invalidPath("\(text) has an empty name") }
        if name == "." || name == ".." { throw .invalidPath("\(text) contains \(name)") }
        if name.contains("/") { throw .invalidPath("\(text) has a slash inside a name") }
        if name.hasPrefix(".") { throw .invalidPath("\(text) has a name that starts with a dot") }
        if name.unicodeScalars.contains("\0") {
            throw .invalidPath("\(text) contains a NUL character")
        }
    }
}
