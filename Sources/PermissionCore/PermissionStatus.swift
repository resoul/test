/// What the system says about one permission.
public enum PermissionStatus: Sendable, Equatable {
    /// Nobody has asked yet, so the system's window can still be shown.
    case notDetermined
    /// The person said yes, in the form `Grant` tells.
    case granted(Grant)
    /// The person said no. The system's window is not shown again; the only way back is the
    /// device's Settings.
    case denied
    /// Asking is not allowed, whatever the person would say: parental controls, a managed device.
    case restricted
    /// This permission does not exist here.
    case unavailable(Reason)

    /// How much was granted. Only the forms a kind really has are here.
    public enum Grant: Sendable, Equatable {
        case full
        /// A part: some of the photos, some of the contacts.
        case limited
        /// Adding and nothing else: events can be created but not read.
        case writeOnly
        /// Notifications delivered quietly, without a prompt, until the person chooses.
        case provisional
        /// Notifications for a short time only, as in an App Clip.
        case ephemeral
        /// Location while the app is in use.
        case whenInUse
        /// Location always.
        case always
    }

    /// Why a permission does not exist.
    public enum Reason: Sendable, Equatable {
        /// The platform has no such permission.
        case platform
        /// This device lacks what the permission is for.
        case hardware
        /// The system version is older than the permission.
        case systemVersion
    }

    /// Whether the app may use the thing the permission protects, in some form.
    public var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }
}
