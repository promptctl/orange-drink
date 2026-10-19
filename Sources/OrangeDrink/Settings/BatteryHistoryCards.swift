import Charts
import SwiftUI

/// design-docs/battery.md "Daily Usage": a bar per stored day of battery discharged and of screen-on
/// time, or the empty state until enough days are collected.
struct DailyUsageCard: View {
    let overview: BatteryOverview

    var body: some View {
        SettingCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Label { PhraseText("DAILY USAGE").font(.caption.weight(.semibold)).foregroundStyle(.secondary) } icon: {
                        Image(systemName: "chart.bar.fill").foregroundStyle(.green)
                    }
                    if let age = overview.collectedAge {
                        Circle().fill(.yellow).frame(width: 7, height: 7).accessibilityHidden(true)
                        PhraseText(age).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if overview.isBuildingUsage { building } else { charts }
            }
            .padding(16)
        }
    }

    private var building: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 28)).foregroundStyle(.green).accessibilityHidden(true)
            PhraseText("Building your daily usage").font(.system(size: 17, weight: .bold))
            PhraseText("\(appName) tracks battery discharge and screen-on time across each day. Come back in a couple of days to see your charts fill in.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            PhraseText(overview.daysCollected).font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.veil(0.1), in: Capsule())
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhraseText("Battery used").font(.caption).foregroundStyle(.secondary)
            Chart(overview.shownDays, id: \.day) {
                BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Used", $0.usage.dischargedPercent)).foregroundStyle(.green)
            }
            .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel("\($0.as(Int.self) ?? 0)%") } }
            .frame(height: 110)
            PhraseText("Screen on").font(.caption).foregroundStyle(.secondary)
            Chart(overview.shownDays, id: \.day) {
                BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Hours", $0.usage.screenOn / 3600)).foregroundStyle(.blue)
            }
            .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel("\($0.as(Double.self).map { Int($0) } ?? 0)h") } }
            .frame(height: 110)
        }
    }
}

/// design-docs/battery.md "Battery Health": today's health and capacities, and the health of each stored day.
struct BatteryHealthCard: View {
    let reading: BatteryReading
    let overview: BatteryOverview
    @Environment(\.appLanguage) private var language

    var body: some View {
        let info = BatteryInformation(reading)
        let color = info.health.condition.color
        SettingCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Battery Health", systemImage: info.health.condition.checkSymbol).font(.system(size: 17, weight: .bold)).foregroundStyle(color)
                    Spacer()
                    InfoButton(text: "How much charge the battery holds today compared with when it was new.")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(info.health.percent).font(.system(size: 28, weight: .bold))
                    PhraseText(info.health.label).foregroundStyle(color)
                    Spacer()
                    Text(reading.capacityText(locale: language.locale)).foregroundStyle(.secondary)
                }
                if overview.isBuildingHealth { building } else { chart(color) }
            }
            .padding(16)
        }
    }

    private var building: some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass").font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
            PhraseText("Building your battery-health history — your health trend fills in as you use your Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func chart(_ color: Color) -> some View {
        Chart(overview.health, id: \.day) {
            LineMark(x: .value("Day", $0.day, unit: .day), y: .value("Health", $0.health * 100)).foregroundStyle(color)
            PointMark(x: .value("Day", $0.day, unit: .day), y: .value("Health", $0.health * 100)).symbolSize(16).foregroundStyle(color)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel("\($0.as(Int.self) ?? 0)%") } }
        .frame(height: 140)
        .accessibilityLabel(Phrase("Battery health over time").text(in: language))
    }
}
