import Foundation

/// Why part of a snapshot was not put back. Restoring never fails as a whole: what could be
/// put back is, and each thing that could not says why.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum RestorationIssue: Hashable, Sendable {
    /// The data is not a snapshot: it does not read.
    case unreadableData
    /// The snapshot is of a version this one does not know; every container stays at its root.
    case unknownVersion(Int)
    /// No beginning of the URL is a path of the stack's routes; the stack stays where it is.
    case unknownPath(String)
    /// The URL was taken in part only: the valid beginning of the path is put back.
    case pathTrimmed(String)
    /// The path does not begin with the stack's root, so it is not this stack's.
    case rootMismatch(String)
    /// A route of the path is one the app does not allow to come back; the path stops before it.
    case routeNotAllowed(String)
    /// The snapshot has a tab that is not there now (its key); the selection stays.
    case unknownTab(String)
    /// The snapshot describes another kind of container than the one there now.
    case shapeMismatch
    /// The container was used before the snapshot came — asked to show something, picked a
    /// tab: what came since is newer, and the snapshot leaves it alone.
    case alreadyNavigated
}

/// What restoring put back.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct RestorationResult: Hashable, Sendable {
    /// Whether anything was put back.
    public internal(set) var isRestored = false

    /// Everything that was not put back, or only in part, and why.
    public internal(set) var issues: [RestorationIssue] = []

    package init(isRestored: Bool = false, issues: [RestorationIssue] = []) {
        self.isRestored = isRestored
        self.issues = issues
    }
}

/// What a scene's containers keep across launches: the paths of the stacks that opted in
/// (`Stack.restorable(using:allowing:)`) as URLs, the tab picked and what each tab shows,
/// whether a split shows its content. It is written as JSON with the version of its schema.
package struct RestorationSnapshot: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var container: Container

    package init(version: Int = RestorationSnapshot.currentVersion, container: Container) {
        self.version = version
        self.container = container
    }

    package indirect enum Container: Codable, Equatable, Sendable {
        case stack(url: String)
        case tabs(selection: String, tabs: [String: Container])
        case split(contentShown: Bool, content: Container?)
    }
}

/// A container that puts its state into a snapshot and takes it back.
@MainActor
protocol Restorable {
    /// What the container keeps, or `nil` when nothing in it opted in.
    func makeSnapshot() -> RestorationSnapshot.Container?

    /// Puts `snapshot` back where it can; what it cannot goes to `issues`. Returns whether
    /// anything was put back.
    func restore(_ snapshot: RestorationSnapshot.Container, issues: inout [RestorationIssue])
        -> Bool
}

extension SceneSession {
    /// The state of the scene's containers, for the platform to keep — `nil` when no container
    /// opted in, so there is nothing to keep.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func restorationData() -> Data? {
        guard let container = (content as? any Restorable)?.makeSnapshot() else { return nil }

        return try? JSONEncoder().encode(RestorationSnapshot(container: container))
    }

    /// Puts back what `data` kept, from `restorationData()` of an earlier run. The scene's
    /// containers that were used since it made them are left alone, so that a link that came
    /// first, or a snapshot that came late, does not undo what is newer. Paths are put back at
    /// once, without the pushes that made them.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: the result says what was not put back.
    /// Cancellation: not applicable.
    @discardableResult
    public func restore(from data: Data) -> RestorationResult {
        guard let snapshot = try? JSONDecoder().decode(RestorationSnapshot.self, from: data)
        else { return RestorationResult(issues: [.unreadableData]) }

        guard snapshot.version == RestorationSnapshot.currentVersion else {
            return RestorationResult(issues: [.unknownVersion(snapshot.version)])
        }

        guard let restorable = content as? any Restorable else {
            return RestorationResult(issues: [.shapeMismatch])
        }

        var issues: [RestorationIssue] = []
        let applied = restorable.restore(snapshot.container, issues: &issues)
        return RestorationResult(isRestored: applied, issues: issues)
    }
}
