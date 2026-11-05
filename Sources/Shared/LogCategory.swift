import Foundation
import os

/// The categories the app and its widget extension log under.
///
/// [LAW:one-source-of-truth] Each category's name is spelled once here. The composition roots, and the
/// few roots SwiftUI or AppKit build on their own (AppDelegate, ShortcutsScreen), all reach the same category through it.
enum LogCategory: String {
    case alerts, devices, battery, hotkey, history, settings, widgets
    case appEnergy = "app-energy"
}

extension Logger {
    init(_ category: LogCategory) {
        self.init(subsystem: Bundle.main.bundleIdentifier!, category: category.rawValue)
    }
}
