import Foundation
import StateCore

/// What a toast offers to do: a word on it — "Undo" — and what it does.
///
/// The toast keeps `perform` until it goes, so the closure should not keep what it undoes alive
/// longer than that.
@MainActor
public struct ToastAction {
    /// The word on the toast's button.
    public let title: String

    let perform: @MainActor () -> Void

    /// Creates an action that carries out `perform` when the user takes it.
    public init(_ title: String, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// A short message over the window that goes by itself: "Message deleted — Undo".
///
///     shell.toast(Toast("Message deleted", action: ToastAction("Undo") { restore() }))
///
/// It stays four seconds, eight when it has an action, longer if `duration` says so; a `persistent`
/// one stays until the user closes it, for what must not be missed. It does not take the
/// keyboard, the focus or the commands of the screen under it. A touch on it holds it; a swipe
/// closes it.
///
/// Toasts of one `group` are one toast: a new one takes the place of the one shown or waiting,
/// with no new appearance, and `counted` says how many there were.
///
///     Toast(
///         "Message deleted",
///         action: ToastAction("Undo") { restore(message) },
///         group: "deleted",
///         counted: { "\($0) messages deleted" }
///     )
@MainActor
public struct Toast {
    /// The words of the toast.
    public let message: String

    /// What the user can do about it, or `nil`. A TV shows no action: its remote has no button
    /// to take it with.
    public let action: ToastAction?

    /// Seconds it stays; `nil` for the usual four, or eight with an action.
    public let duration: Double?

    /// Whether it stays until the user closes it.
    public let isPersistent: Bool

    /// What makes toasts one: a toast of the same group as the one shown, or as one waiting in
    /// the queue, joins it instead of following it. `nil` for a toast that joins none.
    ///
    /// A joined toast takes the newest toast's words, action title and time, and stays
    /// persistent if either was. Taking its action carries out the actions of all the toasts it
    /// joined, the newest first, so "Undo" takes back the latest change before the earlier ones.
    public let group: String?

    /// The words for a toast that joined `count` toasts of its group, two and more; `nil` keeps
    /// `message` whatever the count.
    public let counted: (@MainActor (_ count: Int) -> String)?

    /// Creates a toast; see the type's documentation for `group` and `counted`.
    public init(
        _ message: String,
        action: ToastAction? = nil,
        duration: Double? = nil,
        persistent: Bool = false,
        group: String? = nil,
        counted: (@MainActor (_ count: Int) -> String)? = nil
    ) {
        self.message = message
        self.action = action
        self.duration = duration
        isPersistent = persistent
        self.group = group
        self.counted = counted
    }

    /// How long it stays, in seconds.
    var seconds: Double {
        duration ?? (action == nil ? 4 : 8)
    }

    /// Whether `other`, asked for while this toast is shown or waits, is this one again rather
    /// than a toast of its own. Without a group, the same words with the same action title are
    /// the same toast.
    func isJoined(by other: Toast) -> Bool {
        if let group = other.group { return group == self.group }
        return other.message == message && other.action?.title == action?.title
    }

    /// This toast with `newer` joined to it: the newer one's words and time, and both actions.
    func joining(_ newer: Toast) -> Toast {
        let action: ToastAction?
        switch (newer.action, self.action) {
        case (let newest?, let earlier?):
            action = ToastAction(newest.title) {
                newest.perform()
                earlier.perform()
            }
        case (let only?, nil), (nil, let only?):
            action = only
        case (nil, nil):
            action = nil
        }
        return Toast(
            newer.message,
            action: action,
            duration: newer.duration,
            persistent: newer.isPersistent || isPersistent,
            group: newer.group,
            counted: newer.counted ?? counted
        )
    }
}

/// What a window does with a toast asked for while another one shows.
public enum ToastQueueing: Sendable {
    /// The new toast takes the place of the one shown at once.
    case replace
    /// The new toast waits until the ones shown and waiting before it have gone. A persistent
    /// toast holds the queue until the user closes it.
    case queue
}

/// The toast a window shows now: it is the same one, however many times it is asked for, while
/// its `id` is.
@MainActor
public struct ShownToast {
    /// Stays the same while the toast is joined by others; a new id is a new toast to show.
    public let id: UUID

    /// The toast, with the toasts that joined it folded in.
    public let toast: Toast

    /// How many toasts of the group this one stands for: one until another joins it. A toast
    /// asked for again without a group does not count.
    public let count: Int

    /// The words to show: what `counted` makes of `count` once it is two or more, otherwise the
    /// toast's message. An adapter updates the shown toast in place when they change under the
    /// same `id`.
    public var message: String {
        guard count > 1, let counted = toast.counted else { return toast.message }
        return counted(count)
    }

    func joining(_ newer: Toast) -> ShownToast {
        let counts = newer.group != nil
        return ShownToast(id: id, toast: toast.joining(newer), count: counts ? count + 1 : count)
    }
}

extension SceneSession {
    /// The toast the window shows, or `nil`. Reading it under tracking depends on it; the
    /// platform adapter watches it to show, update and take away the toast and to announce it.
    public var shownToast: ShownToast? {
        toastState.value
    }

    /// The toasts waiting for the one shown to go, first to show first. Empty unless the
    /// shell's ``Shell/toastQueueing`` is ``ToastQueueing/queue``.
    public var queuedToasts: [ShownToast] {
        toastQueue
    }

    /// Shows `toast` over the window.
    ///
    /// A toast that joins the one shown — of its group, or the same words with the same action
    /// title — updates it in place and gives it the time a new one would have; one held under a
    /// finger stays held. A toast that joins none takes the shown one's place, or, when the
    /// shell queues toasts, joins a waiting one or waits at the end of the queue.
    public func show(_ toast: Toast) {
        if let current = toastState.value {
            if current.toast.isJoined(by: toast) {
                let joined = current.joining(toast)
                toastState.value = joined
                restartToastTimer(for: joined.toast)
                return
            }
            if toastQueueing == .queue {
                if let index = toastQueue.firstIndex(where: { $0.toast.isJoined(by: toast) }) {
                    toastQueue[index] = toastQueue[index].joining(toast)
                } else {
                    toastQueue.append(ShownToast(id: UUID(), toast: toast, count: 1))
                }
                return
            }
        }

        present(ShownToast(id: UUID(), toast: toast, count: 1))
    }

    /// Takes the shown toast away; the next one waiting in the queue, if any, shows.
    public func dismissToast() {
        stopToastTimer()
        if toastQueue.isEmpty {
            toastState.value = nil
        } else {
            present(toastQueue.removeFirst())
        }
    }

    /// Takes away the shown toast and every one waiting.
    public func dismissAllToasts() {
        toastQueue.removeAll()
        stopToastTimer()
        toastState.value = nil
    }

    /// The user takes the action of the toast: it is carried out once, and the toast goes.
    public func performToastAction() {
        guard let action = toastState.value?.toast.action else { return }

        dismissToast()
        action.perform()
    }

    /// Holds the toast where it is — a finger on it, VoiceOver reading it: it stays until
    /// `resumeToast()`, which gives it what time it had left, and the queue behind it waits.
    public func holdToast() {
        guard toastState.value != nil, let deadline = toastDeadline else { return }

        toastRemaining = max(deadline.timeIntervalSinceNow, 0.5)
        toastTimer?.cancel()
        toastTimer = nil
        toastDeadline = nil
    }

    /// Lets a held toast go on to its end.
    public func resumeToast() {
        guard let toast = toastState.value?.toast, let remaining = toastRemaining else { return }

        toastRemaining = nil
        startToastTimer(seconds: remaining, persistent: toast.isPersistent)
    }

    private var toastQueueing: ToastQueueing {
        (outer as? Shell)?.toastQueueing ?? .replace
    }

    private func present(_ shown: ShownToast) {
        toastState.value = shown
        startToastTimer(seconds: shown.toast.seconds, persistent: shown.toast.isPersistent)
    }

    /// A joined toast starts its time again — unless it is held: then the time is what it gets
    /// once released, so a finger on it keeps it whatever joins it.
    private func restartToastTimer(for toast: Toast) {
        if toastRemaining != nil {
            toastRemaining = toast.seconds
        } else {
            startToastTimer(seconds: toast.seconds, persistent: toast.isPersistent)
        }
    }

    private func stopToastTimer() {
        toastTimer?.cancel()
        toastTimer = nil
        toastDeadline = nil
        toastRemaining = nil
    }

    private func startToastTimer(seconds: Double, persistent: Bool) {
        stopToastTimer()
        guard !persistent else { return }

        toastDeadline = Date(timeIntervalSinceNow: seconds)
        let shown = toastState.value?.id
        toastTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self, toastState.value?.id == shown else { return }

            dismissToast()
        }
    }
}

extension Shell {
    /// Shows `toast` over the window that is in use: the active one, else the first. Returns
    /// whether there was a window to show it in.
    ///
    ///     shell.toast(Toast("Message deleted", action: ToastAction("Undo") { restore() }))
    @discardableResult
    public func toast(_ toast: Toast) -> Bool {
        guard let session = sessions.first(where: { $0.activation == .active }) ?? sessions.first
        else { return false }

        session.show(toast)
        return true
    }
}
