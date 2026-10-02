import StorageCore
import Testing

@Test(arguments: [
    "", "/a", "a/", "a//b", ".", "..", "a/..", "../a", "a/../b", "a/./b", ".hidden", "a/.b/c",
    "a\u{0}b",
])
func anUnacceptablePathIsRefused(_ text: String) {
    #expect {
        try FilePath(text)
    } throws: { error in
        if case FileError.invalidPath = error { return true }
        return false
    }
}

@Test
func aPathKeepsItsNamesAndFindsItsParent() throws {
    let path = try FilePath("documents/2026/report.pdf")

    #expect(path.components == ["documents", "2026", "report.pdf"])
    #expect(path.name == "report.pdf")
    #expect(path.parent == (try FilePath("documents/2026")))
    #expect(path.parent?.parent?.parent == nil)
    #expect(path.description == "documents/2026/report.pdf")
}

@Test
func appendingAcceptsOnlyOneAcceptableName() throws {
    let directory = try FilePath("a")

    #expect(try directory.appending("b") == (try FilePath("a/b")))
    #expect(throws: FileError.self) { try directory.appending("b/c") }
    #expect(throws: FileError.self) { try directory.appending("..") }
    #expect(throws: FileError.self) { try directory.appending("") }
}

@Test
func pathsAreOrderedByTheirNames() throws {
    let sorted = try ["b", "a/z", "a", "a/b"].map(FilePath.init).sorted()

    #expect(sorted.map(\.description) == ["a", "a/b", "a/z", "b"])
}
