import Foundation

/// A subscription a `ContainerHost` created for a container (D14: the mounted session owns
/// it). The container cancels it when the host detaches it.
///
/// Ownership: the host keeps the delivery; the container keeps this handle. Isolation:
/// MainActor. Errors: none. Cancellation: `cancel()` ends delivery; idempotent.
@MainActor
public protocol ContainerBinding: AnyObject {
    /// Ends delivery.
    ///
    /// Ownership: releases the subscription. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation point.
    func cancel()
}

/// Host services a mounted collection container needs (R12a, ADR 0032). Implemented by the
/// host bridge in TrellisRender; declared here so containers stay in TrellisCore without
/// importing a renderer or platform framework.
///
/// Ownership: the host owns itself; containers reference it weakly. Isolation: MainActor.
/// Errors: none. Cancellation: the host calls `hostDidDetach()` before it stops serving.
@MainActor
public protocol ContainerHost: AnyObject {
    /// Diagnostic host identity (P6.12).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var hostID: UInt64 { get }

    /// The host's shared preparation budget; the host starts a pass after every commit.
    ///
    /// Ownership: owned by the host. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    var materializationBudget: MaterializationBudget { get }

    /// Binds `subject` through the mounted session's state delivery (D14): current value on
    /// start, coalesced latest value afterwards, paused while suspended.
    ///
    /// Ownership: the host owns the delivery; the caller keeps the returned handle. Isolation:
    /// MainActor. Errors: none. Cancellation: the handle's `cancel()`.
    func bindContainerState<Value: Sendable & Equatable>(
        _ subject: StateSubject<Value>,
        update: @escaping @MainActor (Value) -> Void
    ) -> any ContainerBinding

    /// Shifts `node`'s native offset by `delta` in the next geometry commit — the one that
    /// shows the content change the delta compensates — relative to the native offset at that
    /// moment, so a running drag or deceleration keeps its own movement. Unlike a scroll
    /// command it is not refused while the user drives the scroll view. `applied` runs right
    /// before the native offset changes (or when the node left the tree).
    ///
    /// Ownership: retains `applied` until it runs once. Isolation: MainActor. Errors: none.
    /// Cancellation: detaching the host runs every pending `applied`.
    func adjustScrollOffset(
        of node: ScrollNode,
        by delta: LayoutPoint,
        applied: @escaping @MainActor () -> Void
    )

    /// Issues a programmatic scroll command against `node` through the host's scroll command
    /// path (R07): a later command for the same node supersedes this one, user input cancels
    /// it, detaching resolves it `.notAttached`.
    ///
    /// Ownership: retains `completion` until it runs once. Isolation: MainActor. Errors: none —
    /// rejections are outcomes. Cancellation: see `ScrollCommandOutcome`.
    func scrollContainer(
        _ node: ScrollNode,
        _ command: ScrollCommand,
        completion: @escaping @MainActor (ScrollCommandOutcome) -> Void
    )

    /// The offset `node`'s native scroll view shows on screen right now — mid-animation the
    /// presented value, which a gesture grabbing a settling pager continues from (R13). `nil`
    /// when the node has no native backing.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func presentedScrollOffset(of node: ScrollNode) -> LayoutPoint?
}

/// A host's commit, as reported to its containers.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ContainerCommit: Sendable, Hashable {
    /// Render generation of the commit.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let generation: UInt64

    /// Creates a commit report.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(generation: UInt64) {
        self.generation = generation
    }
}

/// A node the host serves with lifecycle and commit notifications (R12a, ADR 0032). The host
/// finds such nodes in its committed tree: a newly present one gets `hostDidAttach`, every
/// present one `hostDidCommit` after each commit, one that left the tree (or the whole tree
/// detached) `hostDidDetach`. Consumers never wire this by hand.
///
/// Ownership: the host references containers weakly. Isolation: MainActor. Errors: none.
/// Cancellation: `hostDidDetach()` must cancel everything the container started for the host.
@MainActor
public protocol HostedContainer: AnyObject {
    /// The container entered a mounted tree of `host`.
    ///
    /// Ownership: keep `host` weakly. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func hostDidAttach(_ host: any ContainerHost)

    /// The host committed geometry; committed frames are readable now. Mutations made here
    /// schedule the next pass.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func hostDidCommit(_ commit: ContainerCommit)

    /// The container left the tree or the host detached.
    ///
    /// Ownership: release host-owned resources. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation point.
    func hostDidDetach()
}
