import Charts
import SwiftUI

/// design-docs/battery.md: the stat tiles and the Battery Level card. Daily usage and health over
/// time come with their own tickets.
struct BatteryScreen: View {
    let battery: BatteryModel
    let history: Result<BatteryHistory, any Error>
    @State private var range = HistoryRange.day
    @State private var loaded: Result<BatteryLevelTimeline, any Error>?
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            tiles
            levelCard
        }
        .padding(24)
        .background(SettingsBackground(glow: .green, glowCenter: .top))
        // The timeline is read again when the range changes and whenever the history is written.
        .task(id: Refresh(range: range, revision: (try? history.get())?.revision)) { load() }
    }

    private struct Refresh: Equatable { let range: HistoryRange; let revision: Int? }

    private func load() {
        loaded = Result { try history.get().timeline(range: range) }
    }

    @ViewBuilder private var tiles: some View {
        switch battery.state {
        case .known(let reading?):
            HStack(spacing: 12) { ForEach(StatTiles(reading).all, id: \.label.key) { StatTile(tile: $0) } }
        case .known(nil): Text("This Mac has no battery.").foregroundStyle(.secondary)
        case .unknown: Text("Reading the battery…").foregroundStyle(.secondary)
        case .ended: Text("Battery readings stopped. Quit and reopen the app.").foregroundStyle(.secondary)
        }
    }

    private var levelCard: some View {
        SettingCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Battery Level", systemImage: "battery.100").font(.system(size: 17, weight: .bold)).foregroundStyle(.green)
                    Spacer()
                    SegmentedPills(selection: $range, options: HistoryRange.allCases, accent: .green, title: \.title)
                }
                switch loaded {
                case nil: EmptyView()
                case .failure: Text("The battery history could not be read. Quit and reopen the app.").foregroundStyle(.secondary)
                case .success(let timeline):
                    summary(timeline)
                    chart(timeline)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func summary(_ timeline: BatteryLevelTimeline) -> some View {
        if let charged = timeline.lastCharged {
            VStack(alignment: .leading, spacing: 2) {
                PhraseText("Last charged to \(charged.level)%").font(.system(size: 17, weight: .bold))
                PhraseText(BatteryLevelTimeline.chargedAt(charged.at, now: timeline.now, calendar: .current, locale: language.locale))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func chart(_ timeline: BatteryLevelTimeline) -> some View {
        if timeline.isBuilding {
            VStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
                PhraseText("Building your battery-level history — your charge timeline fills in as you use your Mac.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            Chart(timeline.points, id: \.at) { point in
                AreaMark(x: .value("Time", point.at), y: .value("Level", point.level)).foregroundStyle(.green.opacity(0.2))
                LineMark(x: .value("Time", point.at), y: .value("Level", point.level)).foregroundStyle(.green)
            }
            .chartXScale(domain: timeline.now.addingTimeInterval(-timeline.range.duration)...timeline.now)
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel("\($0.as(Int.self) ?? 0)%") } }
            .frame(height: 160)
            .accessibilityLabel(Text(verbatim: Phrase("Battery level over the last \(timeline.range.title)").resolve(in: language)))
        }
    }
}

private struct StatTile: View {
    let tile: StatTiles.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { PhraseText(tile.label).font(.caption.weight(.semibold)) } icon: { Image(systemName: tile.symbol).foregroundStyle(tone) }
                .foregroundStyle(.secondary)
            Text(tile.value).font(.system(size: 28, weight: .bold))
            PhraseText(tile.status).font(.callout).foregroundStyle(tone)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.veil(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.veil(0.1), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var tone: Color {
        switch tile.tone {
        case .condition(let condition): condition.color
        case .info: .blue
        }
    }
}
