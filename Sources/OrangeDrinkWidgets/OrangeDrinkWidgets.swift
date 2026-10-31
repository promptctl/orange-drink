import SwiftUI
import WidgetKit
import os

// [LAW:one-source-of-truth] project.yml fills both keys; absent, the extension is a broken build.
let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "widgets")
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String

/// Hands a view the family WidgetKit places it at.
struct FamilyReading<Content: View>: View {
    let content: (WidgetFamily) -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View { content(family) }
}

@main
struct OrangeDrinkWidgets: WidgetBundle {
    var body: some Widget {
        MacBatteryWidget()
        DeviceBatteryWidget()
        AllBatteriesWidget()
    }
}
