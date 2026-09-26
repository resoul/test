import LayoutCore

/// What an accessibility element is, for assistive technologies.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityTraits: OptionSet, Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rawValue: UInt

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let button = AccessibilityTraits(rawValue: 1 << 0)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let header = AccessibilityTraits(rawValue: 1 << 1)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let image = AccessibilityTraits(rawValue: 1 << 2)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let staticText = AccessibilityTraits(rawValue: 1 << 3)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let selected = AccessibilityTraits(rawValue: 1 << 4)
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let notEnabled = AccessibilityTraits(rawValue: 1 << 5)
}

/// How a node presents itself to assistive technologies. Every field left `nil` keeps what
/// the node says by itself: text reads its text, a node with a tap action is a button named
/// by the text inside it, and a node with neither is not an element — its subnodes are.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Accessibility: Sendable, Hashable {
    /// `true` makes the node one element, whose subnodes are not read on their own; `false`
    /// leaves it out, reading its subnodes instead.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var isElement: Bool?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var label: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var value: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var hint: String?
    /// Added to the traits the node has by itself.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var traits: AccessibilityTraits = []

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}
}

/// One element as assistive technologies see it, taken from the tree at its last layout.
/// Platform adapters turn these into `UIAccessibilityElement`s or `NSAccessibilityElement`s.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityItem: Sendable, Hashable {
    /// The node it stands for.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let node: NodeID
    /// In the root's coordinates.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutRect
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let label: String
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let value: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let hint: String?
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let traits: AccessibilityTraits
    /// The item of a list laid out by where it shows (a `LazyStack`) the element belongs to,
    /// or `nil`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var listItem: AccessibilityListItem?
}

/// An item of a list laid out by where it shows: the list's node and the item's index.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityListItem: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let list: NodeID
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let index: Int

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(list: NodeID, index: Int) {
        self.list = list
        self.index = index
    }
}

/// A list laid out by where it shows, as assistive technologies see it: all its items, of
/// which only some are laid out and have elements; the rest stand in with the frame they
/// are expected to take.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityList: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let node: NodeID
    /// All the items.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let count: Int
    /// The items laid out now; the others have no elements.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let laidOut: Range<Int>
    /// The part of the list that shows, in the root's coordinates; the whole list when none
    /// of it shows. Platforms take an empty frame for none at all, and the frames of the
    /// items are measured from this one.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutRect
    /// The direction the items follow each other in.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let axis: ScrollAxis
    /// How many items stand side by side across `axis`; 1 or more.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let lanes: Int

    /// The list as a table: the lines of a vertical list are its rows and the lanes its
    /// columns; a horizontal list is the other way round. A plain vertical list is one column
    /// of rows, a plain horizontal one a row of columns.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var rowCount: Int {
        axis == .vertical ? lineCount : min(lanes, count)
    }

    /// See `rowCount`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var columnCount: Int {
        axis == .vertical ? min(lanes, count) : lineCount
    }

    /// The row and column of the item at `index` in the table `rowCount` describes.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func position(ofItem index: Int) -> (row: Int, column: Int) {
        let line = index / lanes
        let lane = index % lanes
        return axis == .vertical ? (line, lane) : (lane, line)
    }

    /// The index of the item at `row` and `column`, or `nil` when there is none — outside
    /// the table, or past the last item of the last line.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func item(row: Int, column: Int) -> Int? {
        guard row >= 0, column >= 0, row < rowCount, column < columnCount else { return nil }

        let (line, lane) = axis == .vertical ? (row, column) : (column, row)
        let index = line * lanes + lane
        return index < count ? index : nil
    }

    private var lineCount: Int { (count + lanes - 1) / lanes }
}

/// One entry of a tree's accessibility in reading order.
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AccessibilityEntry: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case element(AccessibilityItem)
    /// A list laid out by where it shows, with the elements of its items laid out.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    case list(AccessibilityList, [AccessibilityItem])
}
