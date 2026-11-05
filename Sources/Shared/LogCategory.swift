import Foundation
import os

/// The categories the app and its widget extension log under.
///
/// [LAW:one-source-of-truth] Each category's name, and the subsystem they share, is spelled once here, so every
/// logger made for a category, at a composition root or at a static the root does not yet hand out, writes to it.
enum LogCategory: String {
    case alerts, devices, battery, hotkey, history, settings, widgets, termination, helper, screen, updates
    case appEnergy = "app-energy"
    case appDelegate, launchAtLogin, lowPowerMode, chargeLimit, batteryNotifications

    static let subsystem = Bundle.main.bundleIdentifier!
}

extension Logger {
    init(_ category: LogCategory) {
        self.init(subsystem: LogCategory.subsystem, category: category.rawValue)
    }
}
