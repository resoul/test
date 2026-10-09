import Foundation
import StorageCore
import Testing

@Test
func aMemoryFileStoreStampsFilesFromItsClock() async throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let store = MemoryFileStore(now: { date })

    try await store.write(Data("x".utf8), to: (try FilePath("a.txt")))

    #expect(try await store.metadata(of: (try FilePath("a.txt")))?.modificationDate == date)
}

@Test
func anImportedFileBecomesTheContentOfThePath() async throws {
    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("import-" + UUID().uuidString)
    try Data("outside".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let store = MemoryFileStore()

    try await store.importFile(at: source, to: try FilePath("in/side.txt"))

    #expect(try await store.read(try FilePath("in/side.txt")) == Data("outside".utf8))
}

@Test
func importingAFileThatIsNotThereIsAFailureAndChangesNothing() async throws {
    let store = MemoryFileStore()
    let path = try FilePath("kept.txt")
    try await store.write(Data("kept".utf8), to: path)

    await #expect(throws: FileError.self) {
        try await store.importFile(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("missing-" + UUID().uuidString),
            to: path
        )
    }
    #expect(try await store.read(path) == Data("kept".utf8))
}
