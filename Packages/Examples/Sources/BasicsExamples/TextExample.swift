import Foundation
import LocalizationCore
import RichTextCore
import Tracing
import os

/// Styled text read from Markdown, edited as a value and written back.
///
/// - Returns: The text's Markdown after the first word is made bold.
public func boldFirstWord(of markdown: String) -> String {
    var text = RichText(markdown: markdown)
    let firstWord = text.plainText.prefix { !$0.isWhitespace }
    let range = text.range(utf16Location: 0, length: firstWord.utf16.count)
    text.toggle(.bold, in: range)
    return text.markdown
}

/// A catalog for two languages, with plural forms. In an app the catalog comes from the
/// bundle's string files: `LocalizationCatalog.main`.
public func inboxCatalog() -> LocalizationCatalog {
    var catalog = LocalizationCatalog()
    catalog.insert(.text("Inbox"), for: "inbox.title", language: "en")
    catalog.insert(.text("Входящие"), for: "inbox.title", language: "ru")
    catalog.insert(
        .plural([.one: "%1$@ unread message", .other: "%1$@ unread messages"]),
        for: "inbox.unread",
        language: "en"
    )
    catalog.insert(
        .plural([
            .one: "%1$@ непрочитанное", .few: "%1$@ непрочитанных", .many: "%1$@ непрочитанных",
        ]),
        for: "inbox.unread",
        language: "ru"
    )
    return catalog
}

/// The inbox's subtitle for `count` unread messages in the language of `localeIdentifier`;
/// a language the catalog lacks falls back to English.
public func unreadText(_ count: Int, localeIdentifier: String) -> String {
    let localizer = CatalogLocalizer(catalog: inboxCatalog(), fallbackLanguages: ["en"])
    let text = LocalizedText("inbox.unread", count: count)
    return localizer.resolve(text, locale: Locale(identifier: localeIdentifier)).text
}

/// Marks a stretch of work as a signpost that Instruments shows, and watches the records the
/// way a test or a tool does. The library marks its own work — layout, drawing, decoding,
/// paging — with the same names.
///
/// - Returns: The phases recorded while the work ran.
public func traceDecoding() -> [Trace.Phase] {
    let records = Recorded()
    let observation = Trace.observe { records.append($0) }
    defer { observation.cancel() }

    _ = Trace.measure(.decode, "avatar.png") {
        Data(count: 1024).count
    }
    return records.all.filter { $0.detail == "avatar.png" }.map(\.phase)
}

/// Records collected from whichever thread makes them.
private final class Recorded: Sendable {
    private let records = OSAllocatedUnfairLock<[Trace.Record]>(initialState: [])

    func append(_ record: Trace.Record) {
        records.withLock { $0.append(record) }
    }

    var all: [Trace.Record] { records.withLock { $0 } }
}
