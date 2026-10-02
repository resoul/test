import AsyncRay
import Foundation
import GRDB
import NetworkCore
import StateCore
import StorageCore
import StorageGRDB

/// Where the latest refresh stands. The list itself is never part of it: a refresh that fails or is
/// cancelled leaves the rows as they were, and the failure is shown beside them.
public enum LoadPhase: Sendable, Equatable {
    case idle
    case loading
    case loaded
    /// The refresh failed; `message` says why, in words for the person.
    case failed(String)
}

/// How the live channel is doing, as a screen shows it.
public enum ConnectionStatus: Sendable, Equatable {
    case offline
    case connecting
    case live
    /// The connection was lost and a new one is being made.
    case reconnecting
    /// Gave up, or was refused; `message` says why.
    case failed(String)
}

/// The state of one window's list: the rows, the sort, whether a refresh is running or failed, and the
/// live channel. A window makes its own model; windows share the repository and the preferences,
/// and so see the same data.
///
/// The model reads: the rows come from the database through the repository, and the sort from the
/// preferences, so a change made in any window reaches every model. Its `State`s are read and written
/// on the main actor only.
///
/// Ownership: the model holds the subscriptions it starts and cancels them in ``stop()``, which
/// the owner calls when the window closes; nothing depends on the model being released. The
/// subscriptions hold the model weakly, so releasing it after ``stop()`` frees it at once.
@MainActor
public final class ItemsModel {
    public let rows = State<[ItemRow]>([])
    public let phase = State<LoadPhase>(.idle)
    public let connection = State<ConnectionStatus>(.offline)
    public let sort = State<ItemSort>(.title)
    /// The latest problem with something the person did, such as adding an item; `nil` when there
    /// is none. Cleared by the next successful action.
    public let problem = State<String?>(nil)

    private let repository: ItemsRepository
    private let preferences: any PreferenceStore
    private let subscriptions = SubscriptionBag()
    private var rowsSubscription: Subscription?
    private var work: [Task<Void, Never>] = []

    public init(repository: ItemsRepository, preferences: any PreferenceStore) {
        self.repository = repository
        self.preferences = preferences
    }

    /// Starts watching the preferences, the database and the connection, starts the repository, and
    /// fetches the list. Calling it again while running does nothing.
    public func start() {
        guard rowsSubscription == nil else { return }

        preferences.valuesRay(for: ItemSort.key)
            .sinkOnMain { [weak self] result in self?.sortChanged(result) }
            .store(in: subscriptions)
        repository.connection
            .sinkOnMain { [weak self] state in self?.connection.value = Self.status(of: state) }
            .store(in: subscriptions)
        // Until the preference has been read the list is watched in the default order, so that rows
        // appear without waiting for it.
        watchRows(sortedBy: sort.value)
        // The snapshot first, then the live channel: the channel then continues from the snapshot's
        // cursor instead of racing it with a fetch of its own. If the snapshot fails, the channel
        // is started anyway; it fetches one itself when it connects.
        let repository = repository
        work.append(
            Task { [weak self] in
                await self?.refresh()
                await repository.start()
            }
        )
    }

    /// Stops everything the model started. The rows stay as they are.
    public func stop() {
        subscriptions.cancelAll()
        rowsSubscription?.cancel()
        rowsSubscription = nil
        for task in work { task.cancel() }
        work.removeAll()
    }

    /// Fetches the list again. A refresh that is cancelled is not a failure: the phase goes back to
    /// what it was and the rows are untouched.
    public func refresh() async {
        let previous = phase.value
        phase.value = .loading
        do {
            try await repository.refresh()
            phase.value = .loaded
        } catch {
            if Self.isCancellation(error) {
                phase.value = previous == .loading ? .idle : previous
            } else {
                phase.value = .failed(Self.describe(error))
            }
        }
    }

    /// Adds an item. A failure is reported in ``problem``, and the list is not changed by it.
    public func add(title: String) async {
        do {
            _ = try await repository.add(title: title)
            problem.value = nil
        } catch {
            if !Self.isCancellation(error) { problem.value = Self.describe(error) }
        }
    }

    /// Keeps a file with an item. A failure is reported in ``problem``.
    public func attach(name: String, data: Data, to id: String) async {
        do {
            try await repository.attach(name: name, data: data, to: id)
            problem.value = nil
        } catch {
            if !Self.isCancellation(error) { problem.value = Self.describe(error) }
        }
    }

    /// Sets the order of the list on this device. Every model, in every window, follows.
    public func setSort(_ new: ItemSort) async {
        do {
            try await preferences.set(new, for: ItemSort.key)
        } catch {
            problem.value = Self.describe(error)
        }
    }

    // MARK: Watching

    private func sortChanged(_ result: Result<ItemSort, PreferenceError>) {
        switch result {
        case .success(let new):
            sort.value = new
            watchRows(sortedBy: new)
        case .failure:
            // A damaged setting is not worth a failure of the screen: the default order stays.
            break
        }
    }

    private func watchRows(sortedBy order: ItemSort) {
        rowsSubscription?.cancel()
        rowsSubscription = repository.rows(sortedBy: order).sinkOnMain { [weak self] result in
            switch result {
            case .success(let rows): self?.rows.value = rows
            case .failure(let error): self?.phase.value = .failed(Self.describe(error))
            }
        }
    }

    // MARK: Words

    private static func status(of state: WebSocketState) -> ConnectionStatus {
        switch state {
        case .idle, .closed: .offline
        case .connecting: .connecting
        case .connected: .live
        case .reconnecting: .reconnecting
        case .failed(let error): .failed(describe(error))
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case HTTPError.cancelled = error { return true }
        return false
    }

    /// A reason in plain words. The error's own description is for the log, not the person.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as HTTPError: describe(error)
        case let error as WebSocketError: describe(error)
        // The database's own errors reach a caller either wrapped by the store or as GRDB threw
        // them; either way it is the same trouble.
        case is DatabaseStoreError, is DatabaseError: "The list on this device could not be read."
        case let error as FileError: describe(error)
        default: "Something went wrong."
        }
    }

    private static func describe(_ error: HTTPError) -> String {
        switch error {
        case .transport(let failure):
            failure.kind == .notConnected
                ? "There is no network connection." : "The server could not be reached."
        case .status(let response):
            response.status == 401 || response.status == 403
                ? "The server did not accept your account."
                : "The server answered with an error (\(response.status))."
        case .responseTooLarge: "The server's answer was too large."
        case .decoding, .emptyResponse, .notHTTPResponse:
            "The server's answer could not be understood."
        case .authorizationFailed: "You need to sign in again."
        case .invalidRequest, .encoding: "The request could not be made."
        case .cancelled: "Cancelled."
        }
    }

    private static func describe(_ error: WebSocketError) -> String {
        switch error {
        case .handshakeRejected(let status):
            status == 401 || status == 403
                ? "The server did not accept your account."
                : "The server refused the live connection."
        case .transport: "The live connection could not be made."
        default: "The live connection was lost."
        }
    }

    private static func describe(_ error: FileError) -> String {
        switch error {
        case .noSpace: "There is no space left on this device."
        case .invalidPath: "That file name cannot be used."
        default: "The file could not be saved."
        }
    }
}
