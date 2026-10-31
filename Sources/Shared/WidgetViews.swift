import SwiftUI
import WidgetKit
import os

// Compiled into the app and its widget extension: what the widgets draw. The app compiles them so a test
// renders the real views with no window.

/// The reference ring from design-docs/widgets.md: a dark track, an arc filled clockwise from the top
/// to the level, the glyph in the centre and the percentage below; green with a bolt while charging.
struct BatteryRing: View {
    let battery: WidgetBattery

    private var tint: Color { battery.charging ? .green : .primary }

    var body: some View {
        GeometryReader { space in
            let side = min(space.size.width, space.size.height) * 0.62
            let line = side * 0.1
            VStack(spacing: side * 0.1) {
                ZStack {
                    ZStack {
                        Circle().stroke(.gray.opacity(0.35), lineWidth: line)
                        Circle()
                            .trim(from: 0, to: Double(battery.level?.percent ?? 0) / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        // The bolt sits in a gap cut from the ring: drawn over the green arc it would not read.
                        // Opaque, because destinationOut removes only as much as the cut's own alpha.
                        Circle()
                            .fill(.white)
                            .frame(width: side * 0.26, height: side * 0.26)
                            .offset(y: -side / 2)
                            .blendMode(.destinationOut)
                            .opacity(battery.charging ? 1 : 0)
                    }
                    .compositingGroup()
                    Image(systemName: battery.glyph)
                        .font(.system(size: side * 0.32))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: side * 0.16))
                        .foregroundStyle(.green)
                        .offset(y: -side / 2)
                        .opacity(battery.charging ? 1 : 0)
                }
                .frame(width: side, height: side)
                Text(BatteryLevel.text(battery.level))
                    .font(.system(size: side * 0.2, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct Message: View {
    let glyph: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: glyph).font(.title)
            Text(text).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}

extension Message {
    init(_ reason: UnreadDevices) { self.init(glyph: reason.glyph, text: reason.text) }
}

private extension View {
    /// Every widget's background.
    func widgetBackground() -> some View { containerBackground(.fill.tertiary, for: .widget) }
}

/// The sizes a widget declares, one list per widget so a test reads what the widget offers.
enum WidgetFamilies {
    static let macBattery: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    static let deviceBattery: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    static let allBatteries: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
}

struct MacBatteryEntry: TimelineEntry {
    let date: Date
    /// What the app put on the shelf, or why there is nothing to read.
    let battery: Result<Shelved<MacBattery>, any Error>
}

struct MacBatteryView: View {
    let entry: MacBatteryEntry
    let appName: String

    var body: some View {
        content.widgetBackground()
    }

    @ViewBuilder private var content: some View {
        switch entry.battery {
        case .success(.running(.ended)): Message(glyph: MacBattery.stoppedGlyph, text: "Battery unavailable")
        case .success(.running(let mac)):
            if let battery = mac.battery {
                BatteryRing(battery: battery)
            } else {
                Message(glyph: MacBattery.glyph, text: "No battery")
            }
        case .success(.appNotRunning), .failure: Message(glyph: MacBattery.glyph, text: "Open \(appName)")
        }
    }
}

struct DeviceBatteryEntry: TimelineEntry {
    let date: Date
    /// What the app put on the shelf, or why there is nothing to read.
    let shelf: Result<Shelved<WidgetDevices>, any Error>
    /// The device the widget is set to, by address; nil until one is chosen.
    let chosen: String?
}

/// One device's ring at the widget's size: the ring alone at Small, with the name beside it at Medium
/// and below it at Large.
struct DeviceBatteryView: View {
    let entry: DeviceBatteryEntry
    let appName: String
    /// WidgetKit's environment only reads, so the family arrives as a value a test can pass.
    let family: WidgetFamily

    var body: some View {
        content.widgetBackground()
    }

    @ViewBuilder private var content: some View {
        switch entry.shelf {
        case .failure, .success(.appNotRunning): Message(glyph: "dot.radiowaves.left.and.right", text: "Open \(appName)")
        case .success(.running(.unread(let reason))): Message(reason)
        case .success(.running(.connected(let devices))): chosen(from: devices)
        }
    }

    @ViewBuilder private func chosen(from devices: [WidgetDevice]) -> some View {
        if let address = entry.chosen {
            if let device = devices.first(where: { $0.address == address }) {
                ring(device)
            } else {
                Message(glyph: "dot.radiowaves.left.and.right", text: "Not connected")
            }
        } else {
            Message(glyph: "dot.radiowaves.left.and.right", text: "Choose a device: right-click → Edit Widget")
        }
    }

    @ViewBuilder private func ring(_ device: WidgetDevice) -> some View {
        let ring = BatteryRing(battery: WidgetBattery(device))
        switch family {
        case .systemMedium:
            HStack { ring; name(device) }
        case .systemLarge:
            VStack { ring; name(device) }
        default:
            ring
        }
    }

    private func name(_ device: WidgetDevice) -> some View {
        Text(device.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
    }
}

struct AllBatteriesEntry: TimelineEntry {
    let date: Date
    /// What the app put on the shelf, or why there is nothing to read.
    let mac: Result<Shelved<MacBattery>, any Error>
    let devices: Result<Shelved<WidgetDevices>, any Error>
}

extension AllBatteriesEntry {
    /// What the widget reads: both of the shelf's files, each logged.
    init(date: Date, directory: Result<URL, any Error>, log: Logger) {
        self.init(date: date, mac: WidgetShelf.load(.macBattery, from: directory, log: log), devices: WidgetShelf.load(.devices, from: directory, log: log))
    }
}

/// How many rings a widget of one family holds: the bigger the size, the more batteries fit.
struct RingGrid {
    let columns: Int
    let rows: Int

    init(_ family: WidgetFamily) {
        (columns, rows) = switch family {
        case .systemMedium: (4, 2)
        case .systemLarge: (4, 4)
        case .systemExtraLarge: (8, 4)
        default: (2, 2)
        }
    }

    /// One ring's share of a widget's space.
    func cell(in space: CGSize) -> CGSize {
        CGSize(width: space.width / CGFloat(columns), height: space.height / CGFloat(rows))
    }

    /// As many batteries as fit, a row at a time.
    func rows(of batteries: [WidgetBattery]) -> [[WidgetBattery]] {
        let fitting = Array(batteries.prefix(columns * rows))
        return stride(from: 0, to: fitting.count, by: columns).map { Array(fitting[$0..<min($0 + columns, fitting.count)]) }
    }
}

/// The batteries in rings. [LAW:one-source-of-truth] The grid sets a ring's cell, because a ring grows
/// into whatever it is offered: it is one size however few batteries there are, and the rows are centred.
struct BatteryRings: View {
    let batteries: [WidgetBattery]
    let grid: RingGrid

    var body: some View {
        GeometryReader { space in
            let cell = grid.cell(in: space.size)
            VStack(spacing: 0) {
                ForEach(Array(grid.rows(of: batteries).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, battery in
                            BatteryRing(battery: battery).frame(width: cell.width, height: cell.height)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The Mac's ring, the size the grid makes it, above why no device is beside it.
struct RingAndReason: View {
    let mac: WidgetBattery
    let reason: UnreadDevices
    let grid: RingGrid

    var body: some View {
        GeometryReader { space in
            let cell = grid.cell(in: space.size)
            VStack(spacing: 0) {
                BatteryRing(battery: mac).frame(width: cell.width, height: cell.height)
                Text(reason.text).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(height: cell.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The Mac and every device in one widget.
struct AllBatteriesView: View {
    let entry: AllBatteriesEntry
    let appName: String
    /// WidgetKit's environment only reads, so the family arrives as a value a test can pass.
    let family: WidgetFamily

    var body: some View {
        content.widgetBackground()
    }

    @ViewBuilder private var content: some View {
        switch (entry.mac, entry.devices) {
        case (.success(.running(let mac)), .success(.running(let devices))): rings(AllBatteries(mac: mac, devices: devices))
        default: Message(glyph: MacBattery.glyph, text: "Open \(appName)")
        }
    }

    @ViewBuilder private func rings(_ all: AllBatteries) -> some View {
        switch all {
        case .listed(let batteries) where batteries.isEmpty: Message(glyph: MacBattery.glyph, text: "No batteries")
        case .listed(let batteries): BatteryRings(batteries: batteries, grid: RingGrid(family))
        case .unread(nil, let reason): Message(reason)
        case .unread(let mac?, let reason): RingAndReason(mac: mac, reason: reason, grid: RingGrid(family))
        }
    }
}
