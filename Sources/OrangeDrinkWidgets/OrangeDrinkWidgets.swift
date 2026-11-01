import SwiftUI
import WidgetKit

// [LAW:one-source-of-truth] project.yml fills the key; absent, the extension is a broken build.
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
