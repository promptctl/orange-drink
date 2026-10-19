import SwiftUI

/// The expanded Battery Information card: four sections under thin dividers.
struct BatteryInformationView: View {
    let info: BatteryInformation
    let reading: BatteryReading
    let battery: BatteryModel

    var body: some View {
        VStack(spacing: 12) {
            Divider()
            healthSection
            Divider()
            temperatureSection
            Divider()
            electricalSection
            Divider()
            capacitySection
            footer
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(symbol: info.health.condition.checkSymbol, color: info.health.condition.color, title: "Battery Health",
                          help: "How much charge the battery holds today compared with when it was new.")
            HStack(alignment: .firstTextBaseline) {
                Text(info.health.percent).font(.system(size: 28, weight: .bold)).foregroundStyle(info.health.condition.color)
                Text(info.health.label).foregroundStyle(info.health.condition.color)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(info.health.cycles).font(.system(.body, design: .monospaced).bold())
                    Text("Cycle Count").font(.caption).foregroundStyle(.secondary)
                }
            }
            Gauge(fraction: info.health.fraction, tint: info.health.condition.color)
        }
    }

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(symbol: "thermometer.medium", color: info.temperature.condition.color, title: "Temperature",
                          help: "The battery's own temperature sensor.")
            HStack {
                VStack(alignment: .leading) {
                    Text(info.temperature.celsius).font(.system(size: 24, weight: .bold)).foregroundStyle(info.temperature.condition.color)
                    Text(info.temperature.fahrenheit).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Label(info.temperature.status, systemImage: info.temperature.condition.markSymbol).foregroundStyle(info.temperature.condition.color)
                    Text(info.temperature.caption).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var electricalSection: some View {
        let e = info.electrical
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(symbol: "bolt.circle.fill", color: .green, title: "Power & Electrical",
                          help: "What the battery is drawing or taking in right now.")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Reading(label: "Power Usage", value: e.power)
                    Reading(label: "Voltage", value: e.voltage)
                }
                GridRow {
                    Reading(label: "Current", value: e.current, badge: e.flow == .intoBattery ? "arrow.up.circle.fill" : e.flow == .outOfBattery ? "arrow.down.circle.fill" : nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Label(e.voltageStatus, systemImage: e.charging ? "bolt.fill" : "battery.50")
                            .foregroundStyle(e.charging ? .green : .primary)
                        Text(e.voltageNote).font(.caption).foregroundStyle(e.voltageCondition.color)
                    }
                }
            }
            if let flow = PowerFlow(reading) { PowerFlowView(flow: flow) }
        }
    }

    /// The age is re-read every 10 s while the card is open, so "Updated" keeps counting between readings.
    private var footer: some View {
        VStack(spacing: 4) {
            Label(UpdatedFooter.explanation, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                Text(battery.updatedText() ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Button { battery.refresh() } label: { Label(UpdatedFooter.action, systemImage: "arrow.clockwise").font(.caption) }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity)
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(symbol: "battery.100", color: .blue, title: "Capacity Details",
                          help: "Remaining is the charge in the battery now; Current Full is what a full charge holds today; Design Capacity is what it held when new.")
            CapacityRow(label: "Remaining", value: info.capacity.remaining, color: .green)
            CapacityRow(label: "Current Full", value: info.capacity.full, color: .blue)
            CapacityRow(label: "Design Capacity", value: info.capacity.design, color: .secondary)
        }
    }
}

extension BatteryInformation.Condition {
    var color: Color {
        switch self {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }

    /// A status mark that agrees with the colour: a checkmark only for a healthy reading.
    var markSymbol: String { self == .good ? "checkmark" : "exclamationmark.triangle.fill" }
    var checkSymbol: String { self == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
}

private struct SectionHeader: View {
    let symbol: String, color: Color, title: String, help: String
    @State private var explaining = false

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Button { explaining.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .popover(isPresented: $explaining) { Text(help).padding(10).frame(width: 220) }
        }
    }
}

private struct Reading: View {
    let label: String, value: String
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value).font(.system(.body, design: .monospaced).bold())
                if let badge { Image(systemName: badge).foregroundStyle(.green).font(.caption) }
            }
        }
    }
}

private struct CapacityRow: View {
    let label: String, value: String, color: Color

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(color)
        }
    }
}

private struct Gauge: View {
    let fraction: Double, tint: Color

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint).frame(width: bar.size.width * min(fraction, 1))
            }
        }
        .frame(height: 8)
    }
}
