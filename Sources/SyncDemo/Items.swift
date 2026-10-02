import Foundation
import StorageCore

/// A thing on the server's list. `revision` grows with every change the server makes to it, so a
/// copy with a lower revision is older and never replaces one with a higher.
public struct Item: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var revision: Int

    public init(id: String, title: String, revision: Int) {
        self.id = id
        self.title = title
        self.revision = revision
    }
}

/// A file kept on this device for an item. It exists only here: the server does not know it.
public struct Attachment: Sendable, Equatable {
    public var name: String
    public var size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// An item as the screen shows it: the server's fields and what this device added.
public struct ItemRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var revision: Int
    public var attachment: Attachment?

    public init(id: String, title: String, revision: Int, attachment: Attachment? = nil) {
        self.id = id
        self.title = title
        self.revision = revision
        self.attachment = attachment
    }
}

/// How the list is ordered. A setting of this device, kept in the preferences.
public enum ItemSort: String, Sendable, CaseIterable {
    /// By title, ignoring case.
    case title
    /// The most recently changed first.
    case newest

    public static let key = PreferenceKey("itemSort", default: ItemSort.title)
}
