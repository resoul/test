import StateCore

/// A screen's model: two states and a value computed from them. Reading a state inside
/// `Computed` or `Effect` subscribes to it; nothing has to be declared.
@MainActor
public final class CartModel {
    /// The price of one item, in cents.
    public let price = State(250)
    /// How many items are in the cart.
    public let count = State(1)
    /// The total, recomputed when the price or the count changes and only when it is read.
    public private(set) lazy var total = Computed { self.price.value * self.count.value }

    /// A cart of one item at 2.50.
    public init() {}
}

/// Shows how state, computed values and effects meet: an effect writes the label, and the
/// writes of one stretch reach it once, at the flush.
///
/// - Returns: Every text the label was given, in order.
@MainActor
public func runCart() -> [String] {
    let cart = CartModel()
    var label: [String] = []
    let effect = Effect { label.append("Total: \(cart.total.value)") }

    cart.count.value = 2
    cart.count.value = 3
    cart.price.value = 300
    // Observers run at a flush: the app's run loop flushes on its own; here we flush by hand.
    StateUpdates.flush()

    effect.cancel()
    cart.count.value = 10
    StateUpdates.flush()
    return label
}
