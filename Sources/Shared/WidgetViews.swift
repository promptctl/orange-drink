import SwiftUI
import WidgetKit
import os

// Compiled into the app and its widget extension: what the widgets draw. The app compiles them so a test
// renders the real views with no window.

extension WidgetBattery {
    /// A charging battery is green, wherever and however it is drawn, unless its widget is monochrome.
    var tint: Color { charging && appearance == .color ? .green : .primary }
}

/// A charging battery's bolt, sized by the font its caller sets.
struct BatteryBolt: View {
    let battery: WidgetBattery

    var body: some View {
        Image(systemName: "bolt.fill").foregroundStyle(battery.tint).opacity(battery.charging ? 1 : 0)
    }
}

/// A battery's level in words, sized by the font its caller sets.
struct BatteryPercentage: View {
    let battery: WidgetBattery

    var body: some View {
        Text(BatteryLevel.text(battery.level)).monospacedDigit().foregroundStyle(battery.tint)
    }
}

/// A battery's name on one line, one size in every style and quieter than its level, which at a ring's size it
/// outgrows. Cut in the middle, because a device's name usually starts with its owner's: cut at the end,
/// "Brandon's AirPods" and "Brandon's iPhone" would read the same.
struct BatteryName: View {
    let name: String

    var body: some View { Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
}

/// The reference ring from design-docs/widgets.md: a dark track, an arc filled clockwise from the top
/// to the level, the glyph in the centre and the percentage below; a bolt while charging, in its tint. A name goes under
/// the percentage, and its line's height comes off the ring, so a cell's bolt and name both stay inside it. It stops short
/// of the cell's edges, or two long names side by side would read as one.
struct BatteryRing: View {
    let battery: WidgetBattery

    var body: some View {
        GeometryReader { space in
            let full = min(space.size.width, space.size.height) * 0.62
            let side = battery.name == nil ? full : full - 10
            let line = side * 0.1
            VStack(spacing: side * 0.1) {
                ZStack {
                    ZStack {
                        Circle().stroke(.gray.opacity(0.35), lineWidth: line)
                        Circle()
                            .trim(from: 0, to: BatteryLevel.fraction(battery.level))
                            .stroke(battery.tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
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
                    BatteryBolt(battery: battery)
                        .font(.system(size: side * 0.16))
                        .offset(y: -side / 2)
                }
                .frame(width: side, height: side)
                VStack(spacing: 0) {
                    BatteryPercentage(battery: battery)
                        .font(.system(size: full * 0.2, weight: .bold))
                    if let name = battery.name { BatteryName(name: name).padding(.horizontal, 2) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A row's percentage, in a column every row shares so the bars line up. The bolt hangs off the text's
/// leading edge, in the room "100%" leaves, so it takes none from "~100%", the longest there is.
struct RowPercentage: View {
    static let width: CGFloat = 42
    static let font = Font.subheadline.bold()

    let battery: WidgetBattery

    var body: some View {
        BatteryPercentage(battery: battery)
            .font(Self.font)
            .overlay(alignment: .leading) {
                BatteryBolt(battery: battery).font(.caption2).offset(x: -9)
            }
            .frame(width: Self.width, alignment: .trailing)
    }
}

/// A row's name, when its widget shows names. It takes the row's spare width, which is what puts the percentage in its column.
struct RowName: View {
    let battery: WidgetBattery

    var body: some View {
        if let name = battery.name { BatteryName(name: name).frame(maxWidth: .infinity, alignment: .leading) }
    }
}

/// One battery on one line, starting at its cell's leading edge: its glyph and percentage, either side of whatever a
/// style puts between them. With nothing between them they stay together, so in a table of columns a percentage reads
/// with its own glyph and not the next column's.
struct BatteryRow<Middle: View>: View {
    let battery: WidgetBattery
    @ViewBuilder let middle: Middle

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: battery.glyph).font(.subheadline).frame(width: 20)
            middle
            RowPercentage(battery: battery)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One battery in one style.
struct BatteryCell: View {
    let battery: WidgetBattery
    let style: WidgetStyle

    var body: some View {
        switch style {
        case .rings: BatteryRing(battery: battery)
        case .list: BatteryRow(battery: battery) { RowName(battery: battery) }
        case .bars:
            BatteryRow(battery: battery) {
                VStack(alignment: .leading, spacing: 2) {
                    RowName(battery: battery)
                    LevelBar(fraction: BatteryLevel.fraction(battery.level), tint: battery.tint)
                }
            }
        }
    }
}

/// A widget's small words, however many lines they take.
struct Caption: View {
    let text: String

    var body: some View { Text(text).font(.caption).multilineTextAlignment(.center) }
}

struct Message: View {
    let glyph: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: glyph).font(.title)
            Caption(text: text)
        }
        .foregroundStyle(.secondary)
    }
}

extension Message {
    init(_ reason: NoDevicesListed) { self.init(glyph: reason.glyph, text: reason.text) }
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
        case .failure, .success(.appNotRunning): Message(glyph: DeviceKind.accessory.symbol, text: "Open \(appName)")
        case .success(.running(.unread(let reason))): Message(.unread(reason))
        case .success(.running(.connected(let devices, _))): chosen(from: devices)
        }
    }

    @ViewBuilder private func chosen(from devices: [WidgetDevice]) -> some View {
        if let address = entry.chosen {
            if let device = devices.first(where: { $0.address == address }) {
                ring(device)
            } else {
                Message(glyph: DeviceKind.accessory.symbol, text: "Not connected")
            }
        } else {
            Message(glyph: DeviceKind.accessory.symbol, text: "Choose a device: right-click → Edit Widget")
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
    let settings: AllBatteriesSettings
}

extension AllBatteriesEntry {
    /// What the widget reads: both of the shelf's files, each logged, and the settings it holds.
    init(date: Date, directory: Result<URL, any Error>, log: Logger, configuration: AllBatteriesIntent) {
        let settings = AllBatteriesSettings(configuration)
        self.init(date: date, mac: WidgetShelf.load(.macBattery, from: directory, log: log), devices: WidgetShelf.load(.devices, from: directory, log: log), settings: settings)
        log.notice("widget devices \(settings.devices, privacy: .public) style \(settings.style.rawValue, privacy: .public) names \(settings.showNames, privacy: .public) mac \(settings.includeMac, privacy: .public) appearance \(settings.appearance.rawValue, privacy: .public)")
    }
}

/// How a widget of one family lays out its batteries in one style: the bigger the size, the more fit.
struct BatteryGrid {
    let style: WidgetStyle
    let columns: Int
    let rows: Int
    /// Where a block with room to spare sits, and where a short row sits within it. Rows are a table, so each
    /// keeps its place however few there are.
    let alignment: Alignment

    init(_ family: WidgetFamily, _ style: WidgetStyle) {
        let (ringColumns, ringRows) = switch family {
        case .systemMedium: (4, 2)
        case .systemLarge: (4, 4)
        case .systemExtraLarge: (8, 4)
        default: (2, 2)
        }
        self.style = style
        // [LAW:one-source-of-truth] A row takes two rings' width and half a ring's height, so a size holds the
        // same batteries in every style, and changing style never changes which batteries a widget shows.
        (columns, rows, alignment) = switch style {
        case .rings: (ringColumns, ringRows, .center)
        case .list, .bars: (ringColumns / 2, ringRows * 2, .topLeading)
        }
    }

    /// One battery's share of a widget's space.
    func cell(in space: CGSize) -> CGSize {
        CGSize(width: space.width / CGFloat(columns), height: space.height / CGFloat(rows))
    }

    /// As many batteries as fit, a row at a time.
    func rows(of batteries: [WidgetBattery]) -> [[WidgetBattery]] {
        let fitting = Array(batteries.prefix(columns * rows))
        return stride(from: 0, to: fitting.count, by: columns).map { Array(fitting[$0..<min($0 + columns, fitting.count)]) }
    }
}

/// The batteries in their grid. [LAW:one-source-of-truth] The grid sets a cell, because a ring grows into
/// whatever it is offered: a battery is one size however few there are.
struct BatteryCells: View {
    let batteries: [WidgetBattery]
    let grid: BatteryGrid

    var body: some View {
        GeometryReader { space in
            let cell = grid.cell(in: space.size)
            VStack(alignment: grid.alignment.horizontal, spacing: 0) {
                ForEach(Array(grid.rows(of: batteries).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, battery in
                            BatteryCell(battery: battery, style: grid.style).frame(width: cell.width, height: cell.height)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: grid.alignment)
        }
    }
}

/// The Mac, the size and in the place the grid gives it, above why no device is beside it.
struct BatteryAndReason: View {
    let mac: WidgetBattery
    let reason: NoDevicesListed
    let grid: BatteryGrid

    var body: some View {
        GeometryReader { space in
            let cell = grid.cell(in: space.size)
            VStack(alignment: grid.alignment.horizontal, spacing: 0) {
                BatteryCell(battery: mac, style: grid.style).frame(width: cell.width, height: cell.height)
                // At least a row: a ring's stays where the grid puts it, and a row's is too short for a sentence.
                Caption(text: reason.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(minHeight: cell.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: grid.alignment)
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
        case (.success(.running(let mac)), .success(.running(let devices))): batteries(AllBatteries(mac: mac, devices: devices, settings: entry.settings))
        default: Message(glyph: MacBattery.glyph, text: "Open \(appName)")
        }
    }

    @ViewBuilder private func batteries(_ all: AllBatteries) -> some View {
        let grid = BatteryGrid(family, entry.settings.style)
        switch all {
        case .listed(let batteries) where batteries.isEmpty: Message(glyph: DeviceKind.accessory.symbol, text: "No device batteries")
        case .listed(let batteries): BatteryCells(batteries: batteries, grid: grid)
        case .unlisted(nil, let reason): Message(reason)
        case .unlisted(let mac?, let reason): BatteryAndReason(mac: mac, reason: reason, grid: grid)
        }
    }
}
