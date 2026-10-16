import Foundation
import StorageCore
import StorageFoundation

/// The app's preferences as typed keys: each names its value and the default read while
/// nothing is stored. A key does not say where values live — any `PreferenceStore` keeps them.
public enum Settings {
    /// Whether the reader asked for compact rows.
    public static let compactRows = PreferenceKey("settings.compactRows", default: false)
    /// The width of the last window, in points.
    public static let windowWidth = PreferenceKey("settings.windowWidth", default: 800.0)
}

/// Reads and writes preferences through the protocol, so the same code runs over memory in
/// tests and over `UserDefaults` in the app.
///
/// - Returns: The values read after the writes.
public func updateSettings(in store: some PreferenceStore) async throws -> (
    compact: Bool, width: Double
) {
    try await store.set(true, for: Settings.compactRows)
    try await store.set(1024, for: Settings.windowWidth)
    return (
        try await store.value(for: Settings.compactRows),
        try await store.value(for: Settings.windowWidth)
    )
}

/// The stores the app uses: preferences in `UserDefaults` under a namespace of their own, and
/// files in the caches directory.
public func appStores() throws(FileError) -> (
    preferences: UserDefaultsPreferences, files: DiskFileStore
) {
    (
        UserDefaultsPreferences(namespace: "example."),
        try DiskFileStore(location: .caches, subdirectory: "Example")
    )
}

/// Writes a file under a checked relative path and lists its folder; `FilePath` refuses paths
/// that leave the store, such as `../x`.
///
/// - Returns: The paths in the folder.
public func saveNote(_ text: String, in store: some FileStore) async throws -> [String] {
    try await store.write(Data(text.utf8), to: FilePath("notes/today.txt"))
    return try await store.list(FilePath("notes")).map { "\($0.path)" }
}
