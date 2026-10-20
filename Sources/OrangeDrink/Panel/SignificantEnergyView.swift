import OSLog
import SwiftUI

/// The expanded Apps Using Significant Energy card: the Right Now list from the App Usage screen.
///
/// Built only while the card is open, so a closed card reads nothing; it reloads when a new interval is stored.
struct SignificantEnergyView: View {
    let appEnergy: Result<AppEnergyHistory, any Error>
    @State private var loaded: Result<RightNow, any Error>?
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "app-energy")

    var body: some View {
        Group {
            switch loaded {
            case nil: EmptyView()
            case .failure: Text("App energy history is unavailable. Quit and reopen the app.").font(.caption).foregroundStyle(.secondary)
            case .success(let list):
                VStack(alignment: .leading, spacing: 8) {
                    if list.at != nil {
                        // The age moves with the clock, not with the writes.
                        TimelineView(.everyMinute) { context in
                            if let age = list.age(now: context.date) { PhraseText(age).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    RankedRows(shares: list.shares, highlightFirst: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: (try? appEnergy.get())?.changes.revision) {
            let shares = Result { try appEnergy.get().rightNow() }
            if case .failure(let error) = shares { Self.log.error("panel app energy unreadable: \(String(describing: error), privacy: .public)") }
            loaded = shares
        }
    }
}
