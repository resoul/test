import Foundation
import NetworkCore
import Testing
import os

@testable import NetworkFoundation

// What the delegate makes of the system's reports, driven by hand: the daemon is not involved, so
// these say how an outcome is made, kept and handed out whatever the daemon's mood. The tests that go
// through the daemon are in `BackgroundSystemTests`.

private struct Fixture {
    let directory: URL
    let delegate: BackgroundTransferDelegate

    init(maxReplyBytes: Int = 1024) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-delegate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delegate = BackgroundTransferDelegate(
            directory: directory,
            records: BackgroundTransferRecords(directory: directory),
            redirects: .follow,
            maxReplyBytes: maxReplyBytes
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// A file as the system leaves a finished download, to be moved.
    func downloaded(_ content: Data) throws -> URL {
        let file = directory.appendingPathComponent("system-" + UUID().uuidString)
        try content.write(to: file)
        return file
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
    }

    /// A delegate over the same directory, as the app makes again after it was ended.
    func again() -> BackgroundTransferDelegate {
        BackgroundTransferDelegate(
            directory: directory,
            records: BackgroundTransferRecords(directory: directory),
            redirects: .follow,
            maxReplyBytes: 1024
        )
    }
}

private func answer(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://example.test/x")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

private func download(_ id: String, to path: String) -> BackgroundTransferLabel {
    BackgroundTransferLabel(id: BackgroundTransferID(id), kind: .download, path: path)
}

private func upload(_ id: String) -> BackgroundTransferLabel {
    BackgroundTransferLabel(id: BackgroundTransferID(id), kind: .upload)
}

/// The next outcome of `stream`, or `nil` when none comes within `seconds`.
private func next(
    _ stream: AsyncStream<BackgroundTransferOutcome>,
    within seconds: Double = 5
) async -> BackgroundTransferOutcome? {
    await withTaskGroup(of: BackgroundTransferOutcome?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: Downloads

@Test
func aFinishedDownloadIsPlacedAndItsOutcomeCarriesTheAnswer() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()
    let label = download("d1", to: "files/a.bin")
    let response = answer(200, ["X-Version": "7"])
    let content = Data("content".utf8)

    fixture.delegate.downloaded(
        label,
        taskIdentifier: 1,
        response: response,
        at: try fixture.downloaded(content)
    )
    fixture.delegate.completed(label, taskIdentifier: 1, response: response, error: nil)

    let outcome = try #require(await next(outcomes))
    #expect(outcome.id == "d1")
    #expect(outcome.kind == .download)
    #expect(outcome.status == 200)
    #expect(outcome.headers["X-Version"] == "7")
    #expect(outcome.isSuccess)
    #expect(outcome.body.isEmpty)
    #expect(outcome.file?.lastPathComponent == "a.bin")
    #expect(try Data(contentsOf: try #require(outcome.file)) == content)
}

@Test
func aDownloadReplacesTheFileAlreadyAtItsDestination() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()
    let label = download("d1", to: "a.txt")
    try Data("old".utf8).write(to: fixture.directory.appendingPathComponent("a.txt"))

    fixture.delegate.downloaded(
        label,
        taskIdentifier: 1,
        response: answer(200),
        at: try fixture.downloaded(Data("new".utf8))
    )
    fixture.delegate.completed(label, taskIdentifier: 1, response: answer(200), error: nil)

    #expect(try #require(await next(outcomes)).isSuccess)
    #expect(
        try String(
            contentsOf: fixture.directory.appendingPathComponent("a.txt"),
            encoding: .utf8
        ) == "new"
    )
}

@Test
func aRefusedDownloadLeavesNoFileAndKeepsTheBodyCutAtTheErrorLimit() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()
    let label = download("d1", to: "gone.bin")
    let long = Data(repeating: 0x41, count: HTTPDownload.errorBodyLimit + 5000)

    fixture.delegate.downloaded(
        label,
        taskIdentifier: 1,
        response: answer(404),
        at: try fixture.downloaded(long)
    )
    fixture.delegate.completed(label, taskIdentifier: 1, response: answer(404), error: nil)

    let outcome = try #require(await next(outcomes))
    #expect(outcome.status == 404)
    #expect(!outcome.isSuccess)
    #expect(outcome.failure == nil, "the server did answer")
    #expect(outcome.file == nil)
    #expect(outcome.body.count == HTTPDownload.errorBodyLimit)
    #expect(!fixture.fileExists("gone.bin"))
}

@Test
func aFileThatCannotBePutInPlaceIsAFileSystemFailureNotASuccess() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()
    // A file where the folder of the destination should be.
    try Data("in the way".utf8).write(to: fixture.directory.appendingPathComponent("blocked"))
    let label = download("d1", to: "blocked/a.bin")

    fixture.delegate.downloaded(
        label,
        taskIdentifier: 1,
        response: answer(200),
        at: try fixture.downloaded(Data("x".utf8))
    )
    fixture.delegate.completed(label, taskIdentifier: 1, response: answer(200), error: nil)

    let outcome = try #require(await next(outcomes))
    #expect(outcome.status == 200)
    #expect(outcome.failure?.kind == .fileSystem)
    #expect(!outcome.isSuccess)
    #expect(outcome.file == nil)
}

// MARK: Uploads

@Test
func anUploadsReplyIsCollectedFromItsPieces() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()
    let label = upload("u1")

    #expect(!fixture.delegate.replyReceived(Data("ab".utf8), taskIdentifier: 5))
    #expect(!fixture.delegate.replyReceived(Data("cd".utf8), taskIdentifier: 5))
    fixture.delegate.completed(label, taskIdentifier: 5, response: answer(201), error: nil)

    let outcome = try #require(await next(outcomes))
    #expect(outcome.kind == .upload)
    #expect(outcome.status == 201)
    #expect(String(decoding: outcome.body, as: UTF8.self) == "abcd")
    #expect(outcome.file == nil)
    #expect(outcome.isSuccess)
}

@Test
func aReplyPastTheLimitStopsTheTaskAndTheOutcomeSaysWhy() async throws {
    let fixture = try Fixture(maxReplyBytes: 5)
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()
    let label = upload("u1")

    #expect(!fixture.delegate.replyReceived(Data("abc".utf8), taskIdentifier: 5))
    #expect(fixture.delegate.replyReceived(Data("def".utf8), taskIdentifier: 5), "over the limit")
    // The system reports the task it was told to stop as cancelled; the reason is ours.
    fixture.delegate.completed(
        label,
        taskIdentifier: 5,
        response: answer(200),
        error: URLError(.cancelled)
    )

    let outcome = try #require(await next(outcomes))
    #expect(outcome.failure?.kind == .responseTooLarge)
    #expect(!outcome.isSuccess)
}

// MARK: Failures

@Test(
    arguments: [
        (URLError.Code.cancelled, BackgroundTransferOutcome.Failure.Kind.cancelled),
        (.timedOut, .timedOut),
        (.notConnectedToInternet, .notConnected),
        (.networkConnectionLost, .connectionLost),
        (.cannotConnectToHost, .cannotConnect),
        (.secureConnectionFailed, .secureConnectionFailed),
        (.badServerResponse, .other),
    ]
)
func aTaskThatEndedWithAnErrorGetsTheMatchingFailure(
    code: URLError.Code,
    kind: BackgroundTransferOutcome.Failure.Kind
) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()

    fixture.delegate.completed(
        download("d1", to: "a.bin"),
        taskIdentifier: 1,
        response: nil,
        error: URLError(code)
    )

    let outcome = try #require(await next(outcomes))
    #expect(outcome.failure?.kind == kind)
    #expect(outcome.status == nil)
    #expect(!outcome.isSuccess)
}

@Test
func aTaskThatEndedWithNeitherAnAnswerNorAnErrorIsAFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outcomes = fixture.delegate.outcomes()

    fixture.delegate.completed(
        download("d1", to: "a.bin"),
        taskIdentifier: 1,
        response: nil,
        error: nil
    )

    #expect(try #require(await next(outcomes)).failure?.kind == .other)
}

// MARK: Keeping and handing out

@Test
func aNewListenerIsGivenTheOutcomesNobodyWasWaitingForOldestFirst() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for name in ["first", "second", "third"] {
        let label = download(name, to: name)
        fixture.delegate.downloaded(
            label,
            taskIdentifier: name.count,
            response: answer(200),
            at: try fixture.downloaded(Data(name.utf8))
        )
        fixture.delegate.completed(
            label,
            taskIdentifier: name.count,
            response: answer(200),
            error: nil
        )
        try await Task.sleep(for: .milliseconds(5))
    }

    var iterator = fixture.delegate.outcomes().makeAsyncIterator()
    let ids = [await iterator.next()?.id, await iterator.next()?.id, await iterator.next()?.id]

    #expect(ids == ["first", "second", "third"])
}

@Test
func theRecordsOutliveTheDelegateAndAcknowledgingForgetsOne() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    // A name that is not a safe file name by itself.
    let id = "weird id/with:chars?"
    let label = download(id, to: "k.bin")
    fixture.delegate.downloaded(
        label,
        taskIdentifier: 1,
        response: answer(200, ["ETag": "\"v1\""]),
        at: try fixture.downloaded(Data("kept".utf8))
    )
    fixture.delegate.completed(
        label,
        taskIdentifier: 1,
        response: answer(200, ["ETag": "\"v1\""]),
        error: nil
    )

    // The app was ended and made again: a new delegate over the same directory.
    let relaunched = fixture.again()
    let again = try #require(await next(relaunched.outcomes()))
    #expect(again.id == BackgroundTransferID(id))
    #expect(again.status == 200)
    #expect(again.headers["ETag"] == "\"v1\"")
    #expect(again.file?.lastPathComponent == "k.bin")
    // Not acknowledged: still there for the next time.
    #expect(await next(relaunched.outcomes()) != nil)

    BackgroundTransferRecords(directory: fixture.directory).remove(BackgroundTransferID(id))
    #expect(await next(relaunched.outcomes(), within: 0.3) == nil)
}

@Test
func aRecordThatDoesNotReadDoesNotHideTheOthers() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let label = download("good", to: "a.bin")
    fixture.delegate.downloaded(
        label,
        taskIdentifier: 1,
        response: answer(200),
        at: try fixture.downloaded(Data("x".utf8))
    )
    fixture.delegate.completed(label, taskIdentifier: 1, response: answer(200), error: nil)
    try Data("not json".utf8).write(
        to: fixture.directory
            .appendingPathComponent(BackgroundTransferRecords.folder)
            .appendingPathComponent("broken.json")
    )

    let outcome = try #require(await next(fixture.again().outcomes()))

    #expect(outcome.id == "good")
}

@Test
func aListenerThatJoinsWhileOutcomesArriveMissesNoneAndHearsNoneTwice() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let count = 500
    let delegate = fixture.delegate
    let labels = (0..<count).map { upload("u\($0)") }
    let response = answer(200)

    // Outcomes arrive from the system's queue while a listener joins from somewhere else.
    let arriving = Task.detached {
        DispatchQueue.concurrentPerform(iterations: count) { index in
            delegate.completed(labels[index], taskIdentifier: index, response: response, error: nil)
        }
    }
    try await Task.sleep(for: .milliseconds(1))
    let listener = delegate.outcomes()
    await arriving.value

    let collector = Task { () -> [String] in
        var ids: [String] = []
        for await one in listener { ids.append(one.id.rawValue) }
        return ids
    }
    await arriving.value
    try await Task.sleep(for: .milliseconds(500))
    collector.cancel()
    let ids = await collector.value

    #expect(ids.count == count, "heard \(ids.count) of \(count)")
    #expect(Set(ids).count == ids.count, "some were heard twice")
}

// MARK: Progress and what is not ours

@Test
func theProgressOfATaskIsReportedUnderItsName() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let session = URLSession(configuration: .ephemeral)
    let task = session.downloadTask(with: URL(string: "http://example.test/x")!)
    task.taskDescription = download("d1", to: "a.bin").text
    var progress = fixture.delegate.progress().makeAsyncIterator()

    fixture.delegate.urlSession(
        session,
        downloadTask: task,
        didWriteData: 10,
        totalBytesWritten: 40,
        totalBytesExpectedToWrite: 100
    )
    fixture.delegate.urlSession(
        session,
        downloadTask: task,
        didWriteData: 10,
        totalBytesWritten: 50,
        totalBytesExpectedToWrite: -1
    )

    let first = await progress.next()
    #expect(first == BackgroundTransferProgress(id: "d1", completed: 40, total: 100))
    #expect(
        await progress.next() == BackgroundTransferProgress(id: "d1", completed: 50, total: nil)
    )
}

@Test
func aTaskThatIsNotOursIsLeftAlone() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let session = URLSession(configuration: .ephemeral)
    let foreign = session.dataTask(with: URL(string: "http://example.test/x")!)
    foreign.taskDescription = "something else entirely"
    let outcomes = fixture.delegate.outcomes()

    fixture.delegate.urlSession(session, task: foreign, didCompleteWithError: nil)
    fixture.delegate.urlSession(
        session,
        task: foreign,
        didSendBodyData: 1,
        totalBytesSent: 1,
        totalBytesExpectedToSend: 2
    )

    #expect(await next(outcomes, within: 0.3) == nil)
}

// MARK: What is asked

@Test
func aDestinationOutsideTheDirectoryIsRefused() throws {
    let directory = URL(fileURLWithPath: "/tmp/transfers")
    for path in [
        "", "/etc/passwd", "../out.bin", "a/../../out.bin", "a//b", "./a", "a/",
        BackgroundTransferRecords.folder + "/x",
    ] {
        #expect(throws: HTTPError.self, "\(path)") {
            try BackgroundDestination.resolve(path, in: directory)
        }
    }
    #expect(
        try BackgroundDestination.resolve("a/b.bin", in: directory).path == "/tmp/transfers/a/b.bin"
    )
    #expect(try BackgroundDestination.resolve("a..b", in: directory).lastPathComponent == "a..b")
}

@Test
func aRequestThatCannotBeSentInTheBackgroundIsRefusedBeforeTheSystemSeesIt() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("background-validation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transfers = URLSessionBackgroundTransfers(
        identifier: "tests.background.validation",
        directory: directory
    )
    let url = URL(string: "http://127.0.0.1:1/")!

    await #expect(throws: HTTPError.self) {
        try await transfers.download(HTTPRequest(.post, url, body: Data("x".utf8)), to: "a.bin")
    }
    await #expect(throws: HTTPError.self) {
        try await transfers.download(HTTPRequest(.get, URL(string: "ftp://host/file")!), to: "a")
    }
    await #expect(throws: HTTPError.self) {
        try await transfers.download(HTTPRequest(.get, url), to: "../a")
    }
    await #expect(throws: HTTPError.self) {
        try await transfers.upload(
            HTTPRequest(.put, url),
            fromFile: directory.appendingPathComponent("missing")
        )
    }
}

// MARK: The system's completion

@Test(.timeLimit(.minutes(1)))
func theSystemsCompletionHandlerIsCalledOnceTheEventsAreDelivered() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let delegate = fixture.delegate
    let calls = Calls()

    // Registered first: called when the system says the events are done, not before.
    delegate.finishingEvents { calls.add("first") }
    try await Task.sleep(for: .milliseconds(100))
    #expect(calls.all.isEmpty)
    delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
    while calls.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(calls.all == ["first"])

    // Registered after the events were delivered: called at once, and once.
    delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
    delegate.finishingEvents { calls.add("second") }
    while calls.all.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    delegate.finishingEvents { calls.add("third") }
    try await Task.sleep(for: .milliseconds(100))
    #expect(calls.all == ["first", "second"])
}

@Test(.timeLimit(.minutes(1)))
func eventsDeliveredBeforeNewResultsDoNotCutTheNextHandlerShort() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let delegate = fixture.delegate
    let calls = Calls()

    // The events of an earlier wake-up were all delivered. Then a result arrives, and with it a new
    // wake-up: a handler that is registered now has to wait for that one's end, not for the old.
    delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
    delegate.completed(upload("u1"), taskIdentifier: 1, response: answer(200), error: nil)
    delegate.finishingEvents { calls.add("handler") }
    try await Task.sleep(for: .milliseconds(150))
    #expect(calls.all.isEmpty)

    delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
    while calls.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(calls.all == ["handler"])
}

private final class Calls: Sendable {
    private let names = OSAllocatedUnfairLock(initialState: [String]())

    func add(_ name: String) { names.withLock { $0.append(name) } }

    var all: [String] { names.withLock { $0 } }
}
