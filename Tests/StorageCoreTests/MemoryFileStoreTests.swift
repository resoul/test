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
