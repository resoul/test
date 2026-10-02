import Foundation
import StorageCore
import Testing

/// The behaviour every ``FileStore`` has, checked by the tests of each implementation.
enum FileStoreContract {
    static func path(_ text: String) -> FilePath {
        try! FilePath(text)
    }

    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func run(_ store: any FileStore) async throws {
        try await writesAndReadsBack(store)
        try await replacesWholeContent(store)
        try await reportsMissingAndWrongKind(store)
        try await listsDirectChildrenSorted(store)
        try await removes(store)
        try await moves(store)
        try await refusesAFileAboveAPath(store)
    }

    private static func writesAndReadsBack(_ store: any FileStore) async throws {
        try await store.write(data("hello"), to: path("notes/today/a.txt"))

        #expect(try await store.read(path("notes/today/a.txt")) == data("hello"))
        let file = try await store.metadata(of: path("notes/today/a.txt"))
        #expect(file?.size == 5)
        #expect(file?.isDirectory == false)
        #expect(try await store.metadata(of: path("notes/today"))?.isDirectory == true)
        #expect(try await store.metadata(of: path("nothing")) == nil)
    }

    private static func replacesWholeContent(_ store: any FileStore) async throws {
        try await store.write(data("long first content"), to: path("replace.txt"))
        try await store.write(data("short"), to: path("replace.txt"))

        #expect(try await store.read(path("replace.txt")) == data("short"))
        #expect(try await store.metadata(of: path("replace.txt"))?.size == 5)
    }

    private static func reportsMissingAndWrongKind(_ store: any FileStore) async throws {
        await #expect(throws: FileError.notFound(path("absent.txt"))) {
            try await store.read(path("absent.txt"))
        }
        await #expect(throws: FileError.wrongKind(path("notes"))) {
            try await store.read(path("notes"))
        }
        await #expect(throws: FileError.wrongKind(path("notes"))) {
            try await store.write(data("x"), to: path("notes"))
        }
    }

    private static func listsDirectChildrenSorted(_ store: any FileStore) async throws {
        try await store.write(data("1"), to: path("list/b.txt"))
        try await store.write(data("2"), to: path("list/a.txt"))
        try await store.write(data("3"), to: path("list/sub/deep.txt"))

        let entries = try await store.list(path("list"))

        #expect(entries.map(\.path.description) == ["list/a.txt", "list/b.txt", "list/sub"])
        #expect(entries.map(\.metadata.isDirectory) == [false, false, true])
        #expect(try await store.list(path("never-created")).isEmpty)
        await #expect(throws: FileError.wrongKind(path("list/a.txt"))) {
            try await store.list(path("list/a.txt"))
        }
        let top = try await store.list(nil).map(\.path.description)
        #expect(top.contains("list") && top.contains("notes") && !top.contains("list/a.txt"))
    }

    private static func removes(_ store: any FileStore) async throws {
        try await store.write(data("x"), to: path("gone/a.txt"))
        try await store.write(data("y"), to: path("gone/inner/b.txt"))

        #expect(try await store.remove(path("gone/a.txt")) == true)
        #expect(try await store.remove(path("gone/a.txt")) == false)
        #expect(try await store.remove(path("gone")) == true)
        #expect(try await store.metadata(of: path("gone/inner/b.txt")) == nil)
        #expect(try await store.metadata(of: path("gone")) == nil)
    }

    private static func moves(_ store: any FileStore) async throws {
        try await store.write(data("one"), to: path("mv/a.txt"))
        try await store.move(path("mv/a.txt"), to: path("mv/deeper/b.txt"), replacing: false)
        #expect(try await store.read(path("mv/deeper/b.txt")) == data("one"))
        #expect(try await store.metadata(of: path("mv/a.txt")) == nil)

        await #expect(throws: FileError.notFound(path("mv/a.txt"))) {
            try await store.move(path("mv/a.txt"), to: path("mv/c.txt"), replacing: false)
        }

        try await store.write(data("two"), to: path("mv/c.txt"))
        await #expect(throws: FileError.alreadyExists(path("mv/c.txt"))) {
            try await store.move(path("mv/deeper/b.txt"), to: path("mv/c.txt"), replacing: false)
        }
        #expect(try await store.read(path("mv/deeper/b.txt")) == data("one"))
        try await store.move(path("mv/deeper/b.txt"), to: path("mv/c.txt"), replacing: true)
        #expect(try await store.read(path("mv/c.txt")) == data("one"))

        try await store.write(data("in"), to: path("tree/x/y.txt"))
        try await store.move(path("tree"), to: path("moved"), replacing: false)
        #expect(try await store.read(path("moved/x/y.txt")) == data("in"))
        #expect(try await store.metadata(of: path("tree")) == nil)

        await #expect(throws: FileError.self) {
            try await store.move(path("moved"), to: path("moved/inside"), replacing: false)
        }
    }

    private static func refusesAFileAboveAPath(_ store: any FileStore) async throws {
        try await store.write(data("file"), to: path("block"))

        await #expect(throws: FileError.wrongKind(path("block/child.txt"))) {
            try await store.write(data("x"), to: path("block/child.txt"))
        }
    }
}
