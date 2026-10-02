/// A kind of permission the system asks the person for.
///
/// A kind that comes in levels carries the level, because the system treats the levels as different
/// permissions: it asks for each, answers for each, and wants a different explanation for each.
public enum PermissionKind: Sendable, Hashable {
    case camera
    case microphone
    case photos(PhotoAccess)
    case notifications
    case location(LocationAccess)

    /// How much of the photo library the app wants.
    public enum PhotoAccess: Sendable, Hashable {
        /// Reading the library as well as adding to it.
        case readWrite
        /// Adding photos and nothing else.
        case addOnly
    }

    /// When the app wants the device's location.
    public enum LocationAccess: Sendable, Hashable {
        /// While the app is in use.
        case whenInUse
        /// Also when the app is not in use.
        case always
    }

    /// The `Info.plist` keys whose strings explain to the person why the app asks. Each must be
    /// present and not empty before the system is asked: for some kinds the system ends the app that
    /// asks without one, for others it quietly refuses, and an app is not to find out which in
    /// front of a person.
    ///
    /// Notifications need none.
    public var usageDescriptionKeys: [String] {
        switch self {
        case .camera: ["NSCameraUsageDescription"]
        case .microphone: ["NSMicrophoneUsageDescription"]
        case .photos(.readWrite): ["NSPhotoLibraryUsageDescription"]
        case .photos(.addOnly): ["NSPhotoLibraryAddUsageDescription"]
        case .notifications: []
        case .location(.whenInUse): ["NSLocationWhenInUseUsageDescription"]
        case .location(.always):
            ["NSLocationAlwaysAndWhenInUseUsageDescription", "NSLocationWhenInUseUsageDescription"]
        }
    }
}
