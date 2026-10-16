/// The bar above the keyboard a text field shows while it is edited, where the platform has a
/// keyboard on the screen: iPhone and iPad.
///
/// Ownership: value; `.custom` keeps its closure. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum KeyboardBar {
    /// No bar.
    case none
    /// Previous and next field, and Done: the fields of the tree in the order they are read,
    /// and the keyboard going away.
    case navigation
    /// A tree of the app's own nodes. The closure makes a new one for each field that shows it,
    /// as a node can be in one tree only.
    case custom(@MainActor () -> Node)
}

extension Node {
    /// The bar the text fields under this node show above the keyboard. `nil` leaves it to
    /// the node around; set on a screen's root, it is every field's on the screen, and a field
    /// or any node between can set its own, `.none` included.
    ///
    ///     root.keyboardBar = .navigation
    ///
    /// Read when a field's view is made: set it before the field shows.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var keyboardBar: KeyboardBar? {
        get { keyboardBarStorage }
        set { keyboardBarStorage = newValue }
    }

    /// The bar this node shows: its own, else the nearest one set on a node around it, else
    /// none.
    ///
    /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var effectiveKeyboardBar: KeyboardBar {
        var node: Node? = self
        while let current = node {
            if let bar = current.keyboardBarStorage { return bar }

            node = current.supernode
        }
        return .none
    }
}
