/// How a batch of writes to states is carried out — for example, with an animation, so the
/// UI layer shows what the writes change as a movement. Code that writes states on someone
/// else's behalf, such as a stream bound to a state, takes a transaction and makes its writes
/// inside `perform`, without knowing what the transaction does.
///
/// Ownership: value, held by whoever writes with it. Isolation: `perform` runs on the main
/// actor. Errors: none. Cancellation: not applicable.
public protocol StateTransaction: Sendable {
    /// Runs `writes` as part of this transaction.
    ///
    /// Ownership: runs `writes` once, before returning. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    func perform(_ writes: () -> Void)
}
