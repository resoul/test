import Foundation
import StorageCore
import Testing

@testable import StorageFoundation

/// A directory that lives for one test and is removed after it.
private struct Sandbox: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiskFileStoreTests." + UUID().uuidString, isDirectory: true)

    func store(maxFileSize: Int64? = nil, chunkSize: Int = 1 << 20) -> DiskFileStore {
        DiskFileStore(
            root: url.appendingPathComponent("root"),
            maxFileSize: maxFileSize,
            chunkSize: chunkSize
        )
    }

    var root: URL { url.appendingPathComponent("root") }

    /// A directory beside the root, which no store may touch.
    var outside: URL { url.appendingPathComponent("outside") }

    func remove() {
        // A test may have made a directory unreadable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.appendingPathComponent("locked").path
        )
        try? FileManager.default.removeItem(at: url)
    }

    func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

private func path(_ text: String) -> FilePath { FileStoreContract.path(text) }

private func data(_ text: String) -> Data { Data(text.utf8) }

@Test
func aMemoryFileStoreKeepsTheFileStoreContract() async throws {
    try await FileStoreContract.run(MemoryFileStore())
}

@Test
func aDiskFileStoreKeepsTheFileStoreContract() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }

    try await FileStoreContract.run(sandbox.store())
}

@Test
func theRootIsCreatedByTheFirstWriteNotBefore() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()

    #expect(try await store.list(nil).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: sandbox.root.path))

    try await store.write(data("x"), to: path("a.txt"))
    #expect(
        FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("a.txt").path)
    )
}

@Test
func aWriteLeavesNoTemporaryFileAndAFailedOneKeepsTheOldContent() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store(maxFileSize: 10)
    try await store.write(data("old"), to: path("dir/a.txt"))
    let source = sandbox.url.appendingPathComponent("big.bin")
    try Data(repeating: 7, count: 100).write(
        to: try {
            try FileManager.default.createDirectory(
                at: sandbox.url,
                withIntermediateDirectories: true
            )
            return source
        }()
    )

    await #expect(throws: FileError.tooLarge(path("dir/a.txt"), limit: 10)) {
        try await store.importFile(at: source, to: path("dir/a.txt"))
    }

    #expect(try await store.read(path("dir/a.txt")) == data("old"))
    #expect(sandbox.contents(of: sandbox.root.appendingPathComponent("dir")) == ["a.txt"])
}

@Test
func theSizeLimitAppliesToWritingAndReading() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let limited = sandbox.store(maxFileSize: 4)

    await #expect(throws: FileError.tooLarge(path("a.txt"), limit: 4)) {
        try await limited.write(data("12345"), to: path("a.txt"))
    }
    #expect(try await limited.metadata(of: path("a.txt")) == nil)

    try await sandbox.store().write(data("12345"), to: path("big.txt"))
    await #expect(throws: FileError.tooLarge(path("big.txt"), limit: 4)) {
        try await limited.read(path("big.txt"))
    }
}

@Test
func aLinkUnderTheRootIsNeverFollowed() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    try await store.write(data("inside"), to: path("keep.txt"))
    try FileManager.default.createDirectory(at: sandbox.outside, withIntermediateDirectories: true)
    try data("secret").write(to: sandbox.outside.appendingPathComponent("secret.txt"))
    try FileManager.default.createSymbolicLink(
        at: sandbox.root.appendingPathComponent("link"),
        withDestinationURL: sandbox.outside
    )
    try FileManager.default.createSymbolicLink(
        at: sandbox.root.appendingPathComponent("filelink"),
        withDestinationURL: sandbox.root.appendingPathComponent("keep.txt")
    )

    await #expect(throws: FileError.outsideRoot(path("link/secret.txt"))) {
        try await store.read(path("link/secret.txt"))
    }
    await #expect(throws: FileError.outsideRoot(path("link/new.txt"))) {
        try await store.write(data("x"), to: path("link/new.txt"))
    }
    await #expect(throws: FileError.outsideRoot(path("filelink"))) {
        try await store.write(data("x"), to: path("filelink"))
    }
    await #expect(throws: FileError.outsideRoot(path("link"))) {
        try await store.remove(path("link"))
    }
    await #expect(throws: FileError.outsideRoot(path("link/secret.txt"))) {
        try await store.move(path("keep.txt"), to: path("link/secret.txt"), replacing: true)
    }
    #expect(throws: FileError.outsideRoot(path("link/secret.txt"))) {
        try store.url(for: path("link/secret.txt"))
    }

    #expect(sandbox.contents(of: sandbox.outside) == ["secret.txt"])
    #expect(
        try Data(contentsOf: sandbox.outside.appendingPathComponent("secret.txt")) == data("secret")
    )
    #expect(try await store.read(path("keep.txt")) == data("inside"))
    // A link cannot be addressed, so listing leaves it out too.
    #expect(try await store.list(nil).map(\.path.description) == ["keep.txt"])
}

@Test
func aLargeFileIsCopiedInChunksAndCopyReplaces() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store(chunkSize: 64 * 1024)
    var content = Data()
    for block in 0..<80 { content.append(Data(repeating: UInt8(block), count: 64 * 1024)) }
    content.append(Data([1, 2, 3]))
    try await store.write(content, to: path("big/source.bin"))
    try await store.write(data("old"), to: path("big/copy.bin"))

    try await store.copy(path("big/source.bin"), to: path("big/copy.bin"))

    #expect(try await store.read(path("big/copy.bin")) == content)
    #expect(try await store.read(path("big/source.bin")) == content)
    #expect(
        sandbox.contents(of: sandbox.root.appendingPathComponent("big")) == [
            "copy.bin", "source.bin",
        ]
    )
    await #expect(throws: FileError.notFound(path("nope"))) {
        try await store.copy(path("nope"), to: path("x"))
    }
    await #expect(throws: FileError.wrongKind(path("big"))) {
        try await store.copy(path("big"), to: path("x"))
    }
}

@Test
func importingTakesAFileFromOutsideAndLeavesTheOriginal() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    try FileManager.default.createDirectory(at: sandbox.outside, withIntermediateDirectories: true)
    let picked = sandbox.outside.appendingPathComponent("picked.txt")
    try data("picked").write(to: picked)

    try await store.importFile(at: picked, to: path("attachments/picked.txt"))

    #expect(try await store.read(path("attachments/picked.txt")) == data("picked"))
    #expect(FileManager.default.fileExists(atPath: picked.path))
    await #expect {
        try await store.importFile(
            at: sandbox.outside.appendingPathComponent("missing"),
            to: path("x")
        )
    } throws: { error in
        if case FileError.failed(nil, _) = error { return true }
        return false
    }
    #expect(try await store.metadata(of: path("x")) == nil)
}

@Test
func aCancelledTaskWritesNothing() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    try await store.write(data("old"), to: path("a.txt"))

    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        try await store.write(data("new"), to: path("a.txt"))
    }
    task.cancel()

    await #expect(throws: FileError.cancelled) { try await task.value }
    #expect(try await store.read(path("a.txt")) == data("old"))
    #expect(sandbox.contents(of: sandbox.root) == ["a.txt"])
}

@Test
func cancellingACopyLeavesTheDestinationWholeOrAbsentAndNoTemporaryFile() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store(chunkSize: 1024)
    let content = Data(repeating: 9, count: 8 * 1024 * 1024)
    try await store.write(content, to: path("source.bin"))

    let task = Task { try await store.copy(path("source.bin"), to: path("copy.bin")) }
    try await Task.sleep(for: .milliseconds(2))
    task.cancel()
    let result = await task.result

    switch result {
    case .success:
        // The copy won the race; it is then complete.
        #expect(try await store.read(path("copy.bin")) == content)
    case .failure(let error):
        #expect(error as? FileError == .cancelled)
        #expect(try await store.metadata(of: path("copy.bin")) == nil)
    }
    #expect(sandbox.contents(of: sandbox.root).filter { $0.hasSuffix(".tmp") }.isEmpty)
}

@Test
func leftoverTemporaryFilesAreRemovedAndRealFilesAreNot() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    try await store.write(data("real"), to: path("sub/real.txt"))
    let leftover = sandbox.root.appendingPathComponent("sub/.\(UUID().uuidString).tmp")
    try data("partial").write(to: leftover)
    try data("partial").write(to: sandbox.root.appendingPathComponent(".other.tmp"))

    #expect(try await store.list(path("sub")).map(\.path.description) == ["sub/real.txt"])
    #expect(try await store.removeLeftoverTemporaryFiles() == 2)

    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(try await store.read(path("sub/real.txt")) == data("real"))
}

@Test
func aDirectoryWithoutPermissionGivesAccessDenied() async throws {
    let sandbox = Sandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    try await store.write(data("x"), to: path("locked/a.txt"))
    let locked = sandbox.root.appendingPathComponent("locked").path
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked)
    // A process with every right, such as root, is not stopped by the mode.
    guard !FileManager.default.isWritableFile(atPath: locked) else { return }

    await #expect {
        try await store.write(data("y"), to: path("locked/b.txt"))
    } throws: { error in
        if case FileError.accessDenied = error { return true }
        return false
    }
    #expect(try await store.read(path("locked/a.txt")) == data("x"))
}

@Test
func systemErrorsAreSortedIntoTheCasesACallerCanActOn() {
    let file = path("a.txt")
    func posix(_ code: Int32) -> any Error { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    func cocoa(_ code: Int) -> any Error { NSError(domain: NSCocoaErrorDomain, code: code) }

    #expect(FileError(posix(ENOSPC), path: file) == .noSpace)
    #expect(FileError(cocoa(NSFileWriteOutOfSpaceError), path: nil) == .noSpace)
    #expect(FileError(posix(EACCES), path: file) == .accessDenied(file))
    #expect(FileError(cocoa(NSFileWriteNoPermissionError), path: file) == .accessDenied(file))
    #expect(FileError(cocoa(NSFileReadNoSuchFileError), path: file) == .notFound(file))
    #expect(FileError(posix(EEXIST), path: file) == .alreadyExists(file))
    #expect(FileError(posix(ENOTDIR), path: file) == .wrongKind(file))
    #expect(FileError(CancellationError(), path: file) == .cancelled)

    // Foundation wraps the POSIX error: the wrapped one decides.
    let wrapped = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: posix(ENOSPC)]
    )
    #expect(FileError(wrapped, path: file) == .noSpace)

    // Without a path the specific cases that name one fall back to a general failure.
    guard case .failed(nil, _) = FileError(posix(ENOENT), path: nil) else {
        Issue.record("A not-found error without a path was not a general failure")
        return
    }
}

@Test
func aLocationGivesARootInTheRightSystemDirectory() throws {
    let store = try DiskFileStore(location: .temporary, subdirectory: "Tests/Files")

    let url = try store.url(for: path("a.txt"))
    #expect(
        url.standardizedFileURL.path
            == FileManager.default.temporaryDirectory.appendingPathComponent("Tests/Files/a.txt")
            .standardizedFileURL.path
    )
    #expect(throws: FileError.self) { try DiskFileStore(location: .caches, subdirectory: "../x") }
}
