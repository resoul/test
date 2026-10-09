import PermissionCore

/// Waits for the end of the system's offer to raise location from "when in use" to "always".
///
/// The system does not say that this window ended. If the person raises the access, the status
/// changes; if they keep "when in use", or the system has offered once before and shows nothing
/// now, nothing at all is reported. What can be seen from here is the app itself: while the system's
/// window is up the app is not active, and it is again when the window is gone. So the wait is:
///
/// 1. For a short while, watch for the window. If the status becomes "always", that is the answer.
///    If the app never leaves the front in that time, no window came — it was shown before, or
///    cannot be shown — and the status as it is is the answer.
/// 2. If the app left the front, the window is up: wait, without limit short of `ceiling`, for the
///    app to be active again or the status to change, give the system a moment to settle, and read
///    the status.
///
/// Time goes through `sleep`, so a test runs this without waiting.
struct AlwaysUpgradeWait: Sendable {
    var status: @Sendable () async -> PermissionStatus
    var isInForeground: @Sendable () async -> Bool
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// How long to watch for the window to appear.
    var appearanceWindow: Duration = .milliseconds(1500)
    var poll: Duration = .milliseconds(50)
    /// How long to give the system after the app is active again, for the status to be written.
    var settle: Duration = .milliseconds(300)
    /// The longest the person is waited for.
    var ceiling: Duration = .seconds(600)

    /// The status once the offer is over.
    ///
    /// Cancelling the task ends the wait with the status as it is; the window stays, and what the
    /// person answers is read by the next ``PermissionProvider/status(of:)``.
    func run() async -> PermissionStatus {
        var waited = Duration.zero
        var sawWindow = false
        while waited < appearanceWindow {
            if Task.isCancelled { return await status() }

            let now = await status()
            if now == .granted(.always) { return now }

            if await !isInForeground() {
                sawWindow = true
                break
            }
            await sleep(poll)
            waited += poll
        }
        guard sawWindow else { return await status() }

        waited = .zero
        while waited < ceiling {
            if Task.isCancelled { return await status() }

            let now = await status()
            if now == .granted(.always) { return now }

            if await isInForeground() { break }

            await sleep(poll)
            waited += poll
        }
        await sleep(settle)
        return await status()
    }
}
