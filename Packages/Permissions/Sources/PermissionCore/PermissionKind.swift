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
    case contacts
    case calendar(CalendarAccess)
    case reminders
    /// Using Bluetooth devices. The system asks when the app first uses Bluetooth, and the
    /// status says what the person answered.
    case bluetooth
    case speechRecognition
    /// Following the person across other companies' apps and sites (App Tracking Transparency).
    case tracking
    /// Motion and fitness activity: step counts, activity types, altitude changes.
    case motion
    /// The person's music library.
    case mediaLibrary

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

    /// How much of the calendar the app wants.
    public enum CalendarAccess: Sendable, Hashable {
        /// Reading events as well as adding them.
        case full
        /// Adding events and nothing else.
        case writeOnly
    }

    /// Whether the system can still be asked for this kind when it says `status`.
    ///
    /// Always when nothing has been asked yet. A kind that comes in levels can also be asked again
    /// for a higher level: location "always" after the person chose "when in use", which makes the
    /// system offer to change it. The system shows that offer once; asking after that shows no
    /// window and ends with the status unchanged, so the app must not make "always" a condition
    /// of its screen working.
    public func canBeAsked(whenStatusIs status: PermissionStatus) -> Bool {
        if status == .notDetermined { return true }

        return self == .location(.always) && status == .granted(.whenInUse)
    }

    /// The `Info.plist` keys whose strings explain to the person why the app asks. Each must be
    /// present and not empty before the system is asked: for some kinds the system ends the app that
    /// asks without one, for others it quietly refuses, and an app is not to find out which in
    /// front of a person.
    ///
    /// Notifications need none. Calendar and reminders name the keys of the newest systems — iOS 17
    /// and macOS 14 — which the system provider swaps for the older `NSCalendarsUsageDescription`
    /// and `NSRemindersUsageDescription` on an older system.
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
        case .contacts: ["NSContactsUsageDescription"]
        case .calendar(.full): ["NSCalendarsFullAccessUsageDescription"]
        case .calendar(.writeOnly): ["NSCalendarsWriteOnlyAccessUsageDescription"]
        case .reminders: ["NSRemindersFullAccessUsageDescription"]
        case .bluetooth: ["NSBluetoothAlwaysUsageDescription"]
        case .speechRecognition: ["NSSpeechRecognitionUsageDescription"]
        case .tracking: ["NSUserTrackingUsageDescription"]
        case .motion: ["NSMotionUsageDescription"]
        case .mediaLibrary: ["NSAppleMusicUsageDescription"]
        }
    }
}
