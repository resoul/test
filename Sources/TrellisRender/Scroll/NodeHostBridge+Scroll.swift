import QuartzCore
import TrellisCore

/// A no-op fallback for `NativeScrollBackingFactory`'s delegate parameter, used only when the
/// factory closure `NodeHostBridge.attach(...)` wraps is invoked after its bridge has already
/// deallocated — the closure lives on `renderer`, which cannot outlive the bridge that stores
/// it (`renderer` is a private, non-shared stored property), so this exists purely to keep the
/// wrapper closure total, not because that path is expected to run.
///
/// Ownership: a single shared, stateless instance. Isolation: MainActor. Errors: every call is
/// a no-op. Cancellation: not applicable.
@MainActor
final class NullScrollBackingDelegate: NativeScrollBackingDelegate {
    static let shared = NullScrollBackingDelegate()

    private init() {}

    func scrollBacking(for node: NodeID, didChangeOffset offset: LayoutPoint, phase: ScrollPhase) {}
}

/// `NodeHostBridge`'s R07 scroll surface: `ScrollCommandIssuing` (programmatic commands) and
/// `NativeScrollBackingDelegate` (native-driven offset/phase reporting). Kept in its own file —
/// `NodeHostBridge.swift` is already large — using module-internal (not `private`) access to
/// the handful of stored properties declared there for this purpose.
extension NodeHostBridge: ScrollCommandIssuing {
    /// See `ScrollCommandIssuing.scroll(_:on:completion:)`.
    ///
    /// Resolution order, matching `r06-scroll-api-sketch.md` §7/§9 exactly:
    /// 1. Any pending completion for `node` resolves `.supersededByLaterCommand` synchronously.
    /// 2. No backing yet (never committed, or after `detach()`) → `.notAttached`.
    /// 3. `node` is currently user-driven (`isUserDriven == true`) → `.cancelledByUserInput`
    ///    immediately, never queued over an active gesture (§8).
    /// 4. The command's target offset already equals the current offset → `.completed`
    ///    synchronously, no native call, no pending bookkeeping (scenario 6, §10).
    /// 5. Otherwise the native `scroll(to:animated:completion:)` call is issued and this
    ///    node's pending slot is set to this token.
    ///
    /// Ownership: retains `completion` until it is called exactly once. Isolation: MainActor.
    /// Errors: none — every rejection is a terminal `ScrollCommandOutcome`. Cancellation: user
    /// input starting a gesture while this command is pending resolves it
    /// `.cancelledByUserInput`; `detach()` resolves it `.notAttached`.
    @discardableResult
    public func scroll(
        _ command: ScrollCommand,
        on node: ScrollNode,
        completion: (@MainActor (ScrollCommandOutcome) -> Void)?
    ) -> ScrollCommandToken {
        nextScrollCommandTokenID &+= 1
        let token = ScrollCommandToken(id: nextScrollCommandTokenID)

        if let previous = pendingScrollCompletions.removeValue(forKey: node.id) {
            previous.completion?(.supersededByLaterCommand)
        }

        guard let state = currentScrollState(for: node) else {
            completion?(.notAttached)
            return token
        }
        guard !state.isUserDriven else {
            completion?(.cancelledByUserInput)
            return token
        }

        let target: LayoutPoint
        let animated: Bool
        var timing: Animation?
        switch command {
        case let .to(point, isAnimated):
            target = ScrollState.clamp(
                point,
                contentSize: state.contentSize,
                viewportSize: state.viewportSize
            )
            animated = isAnimated
        case let .by(delta, isAnimated):
            target = ScrollState.clamp(
                LayoutPoint(x: state.offset.x + delta.x, y: state.offset.y + delta.y),
                contentSize: state.contentSize,
                viewportSize: state.viewportSize
            )
            animated = isAnimated
        case let .reveal(frame, alignment, isAnimated):
            target = state.revealOffset(for: frame, alignment: alignment)
            animated = isAnimated
        case let .timed(point, animation):
            target = ScrollState.clamp(
                point,
                contentSize: state.contentSize,
                viewportSize: state.viewportSize
            )
            animated = animation.duration > .zero
            timing = animation
        }

        guard target != state.offset else {
            completion?(.completed(state))
            return token
        }
        guard let backing = renderer.scrollBacking(for: node.id) else {
            completion?(.notAttached)
            return token
        }

        pendingScrollCompletions[node.id] = (token, completion)
        scrollPhases[node.id] = animated ? .settling : .programmatic
        let commandEpoch = hitTestSnapshot?.mountEpoch
        let finish: @MainActor (Bool) -> Void = { [weak self] finished in
            guard let self else { return }
            guard let pending = self.pendingScrollCompletions[node.id], pending.token == token
            else { return }

            self.pendingScrollCompletions.removeValue(forKey: node.id)
            self.scrollPhases[node.id] = .idle
            guard finished else {
                pending.completion?(.cancelledByUserInput)
                return
            }
            guard let finalState = self.publishScrollState(for: node) else {
                pending.completion?(.notAttached)
                return
            }

            if self.hitTestSnapshot?.scrollOffsets[node.id] != finalState.offset {
                self.scrollBacking(for: node.id, didChangeOffset: finalState.offset, phase: .idle)
            }
            guard self.hitTestSnapshot?.mountEpoch == commandEpoch, self.root != nil else {
                pending.completion?(.notAttached)
                return
            }
            pending.completion?(.completed(finalState))
        }
        if let timing, animated {
            backing.scroll(to: target, animation: timing, completion: finish)
        } else {
            backing.scroll(to: target, animated: animated, completion: finish)
        }
        return token
    }

    /// The current `ScrollState` for `node`, read fresh from its backing — `nil` when `node`
    /// has no materialized `NativeScrollBacking` yet.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func currentScrollState(for node: ScrollNode) -> ScrollState? {
        guard let backing = renderer.scrollBacking(for: node.id) else { return nil }

        let contentSize = renderer.scrollContentSize(for: node.id) ?? backing.viewportSize
        let phase = scrollPhases[node.id] ?? .idle
        return ScrollState(
            offset: backing.contentOffset,
            contentSize: contentSize,
            viewportSize: backing.viewportSize,
            phase: phase,
            isUserDriven: phase == .dragging || phase == .decelerating,
            revision: scrollStateRevisions[node.id] ?? 0
        )
    }

    /// Bumps `node`'s revision and publishes a fresh `ScrollState` to it — every offset-only
    /// tick and every geometry commit calls this exactly once per affected node.
    ///
    /// Ownership: nothing retained past the call. Isolation: MainActor. Errors: `nil` when
    /// `node` has no backing (already detached). Cancellation: not applicable.
    @discardableResult
    func publishScrollState(for node: ScrollNode) -> ScrollState? {
        guard let raw = currentScrollState(for: node) else { return nil }

        let bumped = (scrollStateRevisions[node.id] ?? 0) &+ 1
        scrollStateRevisions[node.id] = bumped
        let state = ScrollState(
            offset: raw.offset,
            contentSize: raw.contentSize,
            viewportSize: raw.viewportSize,
            phase: raw.phase,
            isUserDriven: raw.isUserDriven,
            revision: bumped
        )
        node.publish(state)
        return state
    }

    /// Republishes `ScrollState` for every committed `ScrollNode` with a materialized backing —
    /// called after every geometry commit, since content/viewport size can change independent
    /// of any native offset tick (resize, insets change).
    ///
    /// Ownership: nothing retained past the call. Isolation: MainActor. Errors: a node whose
    /// committed route no longer resolves live is silently skipped. Cancellation: not
    /// applicable.
    func publishScrollStates(root: Node) {
        guard let hitTestSnapshot else { return }

        for identity in renderer.scrollBackingIdentities() {
            guard let live = hitTestSnapshot.liveNode(for: identity, under: root) as? ScrollNode
            else { continue }

            publishScrollState(for: live)
        }
    }
}

extension NodeHostBridge: NativeScrollBackingDelegate {
    /// See `NativeScrollBackingDelegate.scrollBacking(for:didChangeOffset:phase:)` — the
    /// offset-only commit path (R07's plan): refreshes `hitTestSnapshot`'s offset table
    /// (`withScrollOffsets(_:)`, no tree re-walk), resolves a pending command with
    /// `.cancelledByUserInput` if user input just began, and republishes `ScrollState` — all
    /// without calling `coordinator.invalidate`/requesting any layout or raster pass.
    ///
    /// Ownership: nothing retained past the call. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func scrollBacking(
        for node: NodeID,
        didChangeOffset offset: LayoutPoint,
        phase: ScrollPhase
    ) {
        guard let hitTestSnapshot, renderer.scrollBacking(for: node) != nil,
            let root, hitTestSnapshot.liveNode(for: node, under: root) is ScrollNode
        else { return }

        var offsets = hitTestSnapshot.scrollOffsets
        offsets[node] = offset
        self.hitTestSnapshot = hitTestSnapshot.withScrollOffsets(offsets)

        scrollPhases[node] = phase
        let isUserDriven = phase == .dragging || phase == .decelerating
        if isUserDriven, let pending = pendingScrollCompletions.removeValue(forKey: node) {
            pending.completion?(.cancelledByUserInput)
        }

        guard self.hitTestSnapshot?.mountEpoch == hitTestSnapshot.mountEpoch else { return }
        // Publish phase before callbacks: a semantic observer must not start a command over
        // the user gesture that caused this very tick.
        publishSemantics(generation: lastCommittedRequest?.generation ?? 0, metadataOnly: false)
        guard self.hitTestSnapshot?.mountEpoch == hitTestSnapshot.mountEpoch,
            let mounted = self.root,
            let live = self.hitTestSnapshot?.liveNode(for: node, under: mounted) as? ScrollNode
        else { return }

        publishScrollState(for: live)
    }
}
