import Foundation
import NetworkCore
import os

/// ``BackgroundTransfers`` over a background `URLSession`.
///
/// **One instance per identifier, for the life of the app.** The system keeps a single session for an
/// identifier and delivers its events to the delegate of the first instance made in the process; a
/// second instance with the same identifier is not told anything. Make it at launch, before the app
/// has anything else to do, because the system may have results waiting for it the moment it exists.
///
/// **After the app was ended.** The system finishes the transfers on its own and starts the app in
/// the background to say so. The app makes this object again with the same identifier and
/// directory; what the delegate then receives is written to the records at once, so
/// ``outcomes()`` has it however late the app starts to listen. An iOS app also hands the system's
/// completion handler to ``finishingEvents(_:)``, which tells the system the app is done with what
/// it was woken for; without that, the system counts the app as slow to return and wakes it less
/// often.
///
/// **Credentials and redirects.** The system follows redirects itself while the app is not running.
/// While it runs, a redirect is judged as ``URLSessionTransport`` judges it: credentials stay with the
/// origin they were addressed to. The system cannot ask the app for a fresh token, so none is
/// renewed; see ``BackgroundTransfers``.
public actor URLSessionBackgroundTransfers: BackgroundTransfers {
    /// The identifier of the session, which the app's delegate matches against the one the system
    /// names when it starts the app.
    public nonisolated let identifier: String
    public nonisolated let directory: URL

    private nonisolated let session: URLSession
    private nonisolated let delegate: BackgroundTransferDelegate
    private nonisolated let records: BackgroundTransferRecords
    /// Names being scheduled, so that two calls for one name start one transfer.
    private var scheduling: Set<BackgroundTransferID> = []

    /// - Parameters:
    ///   - identifier: Names the session across launches; keep it the same.
    ///   - directory: Where downloaded files go and where outcomes are kept. It must be a place that
    ///     lasts and that the app can write to while it is woken in the background; the folder is
    ///     made when it is first used.
    ///   - redirects: What to do with a redirect that arrives while the app runs.
    ///   - isDiscretionary: Whether the system may choose the time, favouring power and Wi-Fi. Right
    ///     for what nobody waits for; wrong for a download the user asked for.
    ///   - allowsCellularAccess: Whether the transfers may use the mobile network.
    ///   - sharedContainerIdentifier: The app group an app extension that starts transfers shares with
    ///     the app, if there is one.
    ///   - timeout: How long the system may keep trying one transfer before it gives up with
    ///     ``BackgroundTransferOutcome/Failure/Kind/timedOut``. A background transfer waits for the
    ///     network to come back instead of failing when it is missing or the server refuses the
    ///     connection, so this is what ends it; the system's own limit is a week.
    ///   - maxReplyBytes: The most bytes of an upload's reply kept; a larger one ends the transfer
    ///     with ``BackgroundTransferOutcome/Failure/Kind/responseTooLarge``.
    public init(
        identifier: String,
        directory: URL,
        redirects: URLSessionTransport.RedirectPolicy = .follow,
        isDiscretionary: Bool = false,
        allowsCellularAccess: Bool = true,
        sharedContainerIdentifier: String? = nil,
        timeout: TimeInterval? = nil,
        maxReplyBytes: Int = 1024 * 1024
    ) {
        let records = BackgroundTransferRecords(directory: directory)
        let delegate = BackgroundTransferDelegate(
            directory: directory,
            records: records,
            redirects: redirects,
            maxReplyBytes: maxReplyBytes
        )
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = isDiscretionary
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.sessionSendsLaunchEvents = true
        configuration.sharedContainerIdentifier = sharedContainerIdentifier
        if let timeout { configuration.timeoutIntervalForResource = timeout }
        self.identifier = identifier
        self.directory = directory
        self.records = records
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        // Lets the identifier be used again. Transfers that are running go on, and the delegate, which
        // the session holds until it is done, still writes their outcomes.
        session.finishTasksAndInvalidate()
    }

    public func download(_ request: HTTPRequest, to path: String, id: BackgroundTransferID?)
        async throws(HTTPError) -> BackgroundTransferID
    {
        guard request.body == nil else {
            throw .invalidRequest("a background download is a request without a body")
        }

        _ = try BackgroundDestination.resolve(path, in: directory)
        let urlRequest = try URLSessionTransport.makeURLRequest(request, includingBody: false)
        let id = id ?? .unique()
        let label = BackgroundTransferLabel(id: id, kind: .download, path: path)
        return await schedule(label) { session.downloadTask(with: urlRequest) }
    }

    public func upload(_ request: HTTPRequest, fromFile file: URL, id: BackgroundTransferID?)
        async throws(HTTPError) -> BackgroundTransferID
    {
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw .fileSystem(
                underlying: CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: file])
            )
        }

        let urlRequest = try URLSessionTransport.makeURLRequest(request, includingBody: false)
        let id = id ?? .unique()
        let label = BackgroundTransferLabel(id: id, kind: .upload)
        return await schedule(label) { session.uploadTask(with: urlRequest, fromFile: file) }
    }

    /// Starts the task `make` creates unless a transfer of that name already exists.
    private func schedule(
        _ label: BackgroundTransferLabel,
        make: () -> URLSessionTask
    ) async -> BackgroundTransferID {
        let id = label.transferID
        guard !records.contains(id), scheduling.insert(id).inserted else { return id }

        defer { scheduling.remove(id) }
        // Any task of that name counts, one being cancelled or just done included: its outcome is
        // still to come, and until it has been acknowledged the name is taken.
        let alive = await session.allTasks.contains {
            BackgroundTransferLabel($0)?.transferID == id
        }
        if !alive {
            let task = make()
            task.taskDescription = label.text
            task.resume()
        }
        return id
    }

    public func transfers() async -> [BackgroundTransferInfo] {
        await session.allTasks.compactMap { task in
            guard let label = BackgroundTransferLabel(task) else { return nil }

            let state: BackgroundTransferInfo.State
            switch task.state {
            case .running: state = .running
            case .suspended: state = .suspended
            default: state = .finishing
            }
            let isUpload = label.transferKind == .upload
            let expected =
                isUpload ? task.countOfBytesExpectedToSend : task.countOfBytesExpectedToReceive
            return BackgroundTransferInfo(
                id: label.transferID,
                kind: label.transferKind,
                state: state,
                progress: BackgroundTransferProgress(
                    id: label.transferID,
                    completed: isUpload ? task.countOfBytesSent : task.countOfBytesReceived,
                    total: expected > 0 ? expected : nil
                )
            )
        }
    }

    public func cancel(_ id: BackgroundTransferID) async {
        for task in await session.allTasks where BackgroundTransferLabel(task)?.transferID == id {
            task.cancel()
        }
    }

    public nonisolated func outcomes() -> AsyncStream<BackgroundTransferOutcome> {
        delegate.outcomes()
    }

    public nonisolated func progress() -> AsyncStream<BackgroundTransferProgress> {
        delegate.progress()
    }

    public func acknowledge(_ id: BackgroundTransferID) async {
        records.remove(id)
    }

    /// Tells the system the app has dealt with the events it was woken for.
    ///
    /// Pass the completion handler that the app delegate's
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` receives. It is called
    /// on the main actor once every event of the session has been delivered and written — at once,
    /// if that has happened already.
    public nonisolated func finishingEvents(_ completion: @escaping @MainActor @Sendable () -> Void)
    {
        delegate.finishingEvents(completion)
    }
}

/// Receives what the system reports about every task of one session, and turns it into records.
///
/// A callback never relies on what an earlier one left in memory beyond the file or reply of the
/// task it is about: the task's label says what it is, because after the app was ended the delegate
/// of a transfer that began in an earlier life is the only thing that knows about it.
final class BackgroundTransferDelegate: NSObject, URLSessionDownloadDelegate,
    URLSessionDataDelegate,
    Sendable
{
    private enum Download: Sendable {
        case placed(URL)
        /// The answer was not a success; its body is kept, cut.
        case refused(Data)
        case failed(any Error)
    }

    private struct State: Sendable {
        var downloads: [Int: Download] = [:]
        var replies: [Int: Data] = [:]
        var stopped: [Int: BackgroundTransferOutcome.Failure] = [:]
        var outcomeListeners: [UUID: AsyncStream<BackgroundTransferOutcome>.Continuation] = [:]
        var progressListeners: [UUID: AsyncStream<BackgroundTransferProgress>.Continuation] = [:]
        var completion: (@MainActor @Sendable () -> Void)?
        var eventsFinished = false
    }

    private let directory: URL
    private let records: BackgroundTransferRecords
    private let redirects: URLSessionTransport.RedirectPolicy
    private let maxReplyBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        directory: URL,
        records: BackgroundTransferRecords,
        redirects: URLSessionTransport.RedirectPolicy,
        maxReplyBytes: Int
    ) {
        self.directory = directory
        self.records = records
        self.redirects = redirects
        self.maxReplyBytes = maxReplyBytes
    }

    // MARK: Listening

    func outcomes() -> AsyncStream<BackgroundTransferOutcome> {
        let (stream, continuation) = AsyncStream.makeStream(of: BackgroundTransferOutcome.self)
        let key = UUID()
        // The records are read and the listener added under one lock, which an arriving outcome
        // also holds from writing its record to telling the listeners: no outcome is missed, and none
        // is given twice.
        state.withLock { state in
            for record in records.all() { continuation.yield(record.outcome(in: directory)) }
            state.outcomeListeners[key] = continuation
        }
        continuation.onTermination = { [state] _ in
            state.withLock { _ = $0.outcomeListeners.removeValue(forKey: key) }
        }
        return stream
    }

    func progress() -> AsyncStream<BackgroundTransferProgress> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: BackgroundTransferProgress.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let key = UUID()
        state.withLock { $0.progressListeners[key] = continuation }
        continuation.onTermination = { [state] _ in
            state.withLock { _ = $0.progressListeners.removeValue(forKey: key) }
        }
        return stream
    }

    func finishingEvents(_ completion: @escaping @MainActor @Sendable () -> Void) {
        let ready = state.withLock { state -> Bool in
            if state.eventsFinished {
                state.eventsFinished = false
                return true
            }
            state.completion = completion
            return false
        }
        if ready { Task { @MainActor in completion() } }
    }

    private func report(_ progress: BackgroundTransferProgress) {
        state.withLock { state in
            for listener in state.progressListeners.values { listener.yield(progress) }
        }
    }

    // MARK: Progress

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let label = BackgroundTransferLabel(downloadTask) else { return }

        report(
            BackgroundTransferProgress(
                id: label.transferID,
                completed: totalBytesWritten,
                total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let label = BackgroundTransferLabel(task) else { return }

        report(
            BackgroundTransferProgress(
                id: label.transferID,
                completed: totalBytesSent,
                total: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil
            )
        )
    }

    // MARK: Results

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let label = BackgroundTransferLabel(downloadTask) else { return }

        downloaded(
            label,
            taskIdentifier: downloadTask.taskIdentifier,
            response: downloadTask.response as? HTTPURLResponse,
            at: location
        )
    }

    /// The file the system downloaded is deleted when this returns, so it is put in place, or read for
    /// the body of a refusal, before then.
    func downloaded(
        _ label: BackgroundTransferLabel,
        taskIdentifier: Int,
        response: HTTPURLResponse?,
        at location: URL
    ) {
        guard let path = label.path else { return }

        let result: Download
        if let response, !(200...299).contains(response.statusCode) {
            let handle = try? FileHandle(forReadingFrom: location)
            defer { try? handle?.close() }
            result = .refused(
                (try? handle?.read(upToCount: HTTPDownload.errorBodyLimit)) ?? Data()
            )
        } else {
            do {
                let destination = try BackgroundDestination.resolve(path, in: directory)
                try Self.place(location, at: destination)
                result = .placed(destination)
            } catch {
                result = .failed(error)
            }
        }
        state.withLock { $0.downloads[taskIdentifier] = result }
    }

    private static func place(_ location: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: location)
        } else {
            try fileManager.moveItem(at: location, to: destination)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if replyReceived(data, taskIdentifier: dataTask.taskIdentifier) { dataTask.cancel() }
    }

    /// An upload's reply arrives in pieces; it is kept up to the limit.
    ///
    /// - Returns: Whether the reply has passed the limit, in which case the task is to be stopped
    ///   and its outcome says why.
    func replyReceived(_ data: Data, taskIdentifier: Int) -> Bool {
        state.withLock { state in
            var reply = state.replies[taskIdentifier] ?? Data()
            if reply.count + data.count > maxReplyBytes {
                state.stopped[taskIdentifier] = BackgroundTransferOutcome.Failure(
                    kind: .responseTooLarge,
                    message: "the reply is larger than \(maxReplyBytes) bytes"
                )
                return true
            }
            reply.append(data)
            state.replies[taskIdentifier] = reply
            return false
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let label = BackgroundTransferLabel(task) else { return }

        completed(
            label,
            taskIdentifier: task.taskIdentifier,
            response: task.response as? HTTPURLResponse,
            error: error
        )
    }

    /// A task is over: its outcome is made from what the earlier callbacks left, written down, and
    /// told to those listening.
    func completed(
        _ label: BackgroundTransferLabel,
        taskIdentifier: Int,
        response: HTTPURLResponse?,
        error: (any Error)?
    ) {
        let (download, reply, stopped) = state.withLock { state in
            (
                state.downloads.removeValue(forKey: taskIdentifier),
                state.replies.removeValue(forKey: taskIdentifier),
                state.stopped.removeValue(forKey: taskIdentifier)
            )
        }
        var outcome = BackgroundTransferOutcome(id: label.transferID, kind: label.transferKind)
        var relativeFile: String?
        if let http = response {
            outcome.status = http.statusCode
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String {
                    outcome.headers.add(value, for: name)
                }
            }
        }
        switch label.transferKind {
        case .upload:
            outcome.body = reply ?? Data()
        case .download:
            switch download {
            case .placed(let file)?:
                outcome.file = file
                relativeFile = label.path
            case .refused(let body)?: outcome.body = body
            case .failed(let error)?:
                outcome.failure = .init(kind: .fileSystem, message: "\(error)")
            case nil: break
            }
        }
        if let stopped {
            outcome.failure = stopped
        } else if outcome.failure == nil, let error {
            outcome.failure = Self.failure(of: error)
        } else if outcome.failure == nil, outcome.status == nil {
            outcome.failure = .init(kind: .other, message: "the answer was not an HTTP response")
        }
        if outcome.failure != nil { outcome.file = nil }

        let finished = outcome
        let record = BackgroundTransferRecord(
            finished,
            relativeFile: finished.file == nil ? nil : relativeFile
        )
        state.withLock { state in
            state.eventsFinished = false
            // A record that cannot be written still goes to those listening now: losing it for the
            // next launch is bad, but hiding it from this one would be worse.
            try? records.write(record)
            for listener in state.outcomeListeners.values { listener.yield(finished) }
        }
    }

    static func failure(of error: any Error) -> BackgroundTransferOutcome.Failure {
        let message = (error as NSError).localizedDescription
        switch URLSessionTransport.map(error) {
        case .cancelled: return .init(kind: .cancelled, message: message)
        case .transport(let failure):
            let kind: BackgroundTransferOutcome.Failure.Kind
            switch failure.kind {
            case .timedOut: kind = .timedOut
            case .connectionLost: kind = .connectionLost
            case .cannotConnect: kind = .cannotConnect
            case .notConnected: kind = .notConnected
            case .secureConnectionFailed: kind = .secureConnectionFailed
            case .other: kind = .other
            }
            return .init(kind: kind, message: message)
        default: return .init(kind: .other, message: message)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectRules.decide(policy: redirects, task: task, response: response, newRequest: request)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = state.withLock { state -> (@MainActor @Sendable () -> Void)? in
            guard let handler = state.completion else {
                state.eventsFinished = true
                return nil
            }

            state.completion = nil
            return handler
        }
        if let handler { Task { @MainActor in handler() } }
    }
}
