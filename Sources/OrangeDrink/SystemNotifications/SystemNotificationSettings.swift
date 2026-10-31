import Foundation

/// The General screen's System Notifications section. The switch is the user's choice, so it stays on whether or not the
/// app has been given what it needs to act on it.
struct SystemNotificationSettings: Stored {
    static let storageKey = "systemNotifications"

    var dismissBatteryNotifications = false
}

typealias SystemNotificationSettingsModel = StoredModel<SystemNotificationSettings>
