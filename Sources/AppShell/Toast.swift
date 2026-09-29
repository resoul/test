import Foundation
import StateCore

/// What a toast offers to do: a word on it — "Undo" — and what it does.
///
/// Ownership: keeps `perform`, which must not keep what it undoes alive longer than a toast.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public struct ToastAction {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let title: String

    let perform: @MainActor () -> Void

    /// Ownership: keeps `perform`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
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
/// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public struct Toast {
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let message: String

    /// What the user can do about it, or `nil`. A TV shows no action: its remote has no button
    /// to take it with.
    ///
    /// Ownership: keeps the action. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let action: ToastAction?

    /// Seconds it stays; `nil` for the usual four, or eight with an action.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let duration: Double?

    /// Whether it stays until the user closes it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let isPersistent: Bool

    /// Ownership: keeps the action. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(
        _ message: String,
        action: ToastAction? = nil,
        duration: Double? = nil,
        persistent: Bool = false
    ) {
        self.message = message
        self.action = action
        self.duration = duration
        isPersistent = persistent
    }

    /// How long it stays, in seconds.
    var seconds: Double {
        duration ?? (action == nil ? 4 : 8)
    }
}

/// The toast a window shows now: it is the same one, however many times it is asked for, while
/// its `id` is.
///
/// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public struct ShownToast {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: UUID

    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let toast: Toast
}

extension SceneSession {
    /// The toast the window shows, or `nil`. Reading it under tracking depends on it; the
    /// platform adapter watches it to show and take away the toast and to announce it.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var shownToast: ShownToast? {
        toastState.value
    }

    /// Shows `toast` over the window, in the place of the one shown. The same message with the
    /// same action title as the one shown is it again: it stays as long as a new one would,
    /// and nothing else changes.
    ///
    /// Ownership: keeps the toast until it goes. Isolation: MainActor. Errors: none.
    /// Cancellation: `dismissToast()`.
    public func show(_ toast: Toast) {
        if let current = toastState.value,
            current.toast.message == toast.message,
            current.toast.action?.title == toast.action?.title
        {
            startToastTimer(seconds: toast.seconds, persistent: toast.isPersistent)
            return
        }

        toastState.value = ShownToast(id: UUID(), toast: toast)
        startToastTimer(seconds: toast.seconds, persistent: toast.isPersistent)
    }

    /// Takes the toast away.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func dismissToast() {
        toastTimer?.cancel()
        toastTimer = nil
        toastDeadline = nil
        toastRemaining = nil
        toastState.value = nil
    }

    /// The user takes the action of the toast: it is carried out once, and the toast goes.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func performToastAction() {
        guard let action = toastState.value?.toast.action else { return }

        dismissToast()
        action.perform()
    }

    /// Holds the toast where it is — a finger on it, VoiceOver reading it: it stays until
    /// `resumeToast()`, which gives it what time it had left.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func holdToast() {
        guard toastState.value != nil, let deadline = toastDeadline else { return }

        toastRemaining = max(deadline.timeIntervalSinceNow, 0.5)
        toastTimer?.cancel()
        toastTimer = nil
        toastDeadline = nil
    }

    /// Lets a held toast go on to its end.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func resumeToast() {
        guard let toast = toastState.value?.toast, let remaining = toastRemaining else { return }

        toastRemaining = nil
        startToastTimer(seconds: remaining, persistent: toast.isPersistent)
    }

    private func startToastTimer(seconds: Double, persistent: Bool) {
        toastTimer?.cancel()
        toastTimer = nil
        toastRemaining = nil
        guard !persistent else {
            toastDeadline = nil
            return
        }

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
    ///
    /// Ownership: keeps the toast until it goes. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func toast(_ toast: Toast) -> Bool {
        guard let session = sessions.first(where: { $0.activation == .active }) ?? sessions.first
        else { return false }

        session.show(toast)
        return true
    }
}
