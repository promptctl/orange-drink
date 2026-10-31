import SwiftUI
import WidgetKit

// Compiled into the app and its widget extension: what the widgets draw. The app compiles them so a test
// renders the real views with no window.

/// The reference ring from design-docs/widgets.md: a dark track, an arc filled clockwise from the top
/// to the level, the glyph in the centre and the percentage below; green with a bolt while charging.
struct BatteryRing: View {
    /// nil while there is no reading yet: the empty track.
    let level: Int?
    let charging: Bool
    /// The level is an estimate (a device that reports only a coarse step): shown "~40%", as the panel shows it.
    var approximate = false
    /// The SF Symbol in the centre: the laptop for the Mac, the device's kind for a device.
    let glyph: String

    private var tint: Color { charging ? .green : .primary }

    var body: some View {
        GeometryReader { space in
            let side = min(space.size.width, space.size.height) * 0.62
            let line = side * 0.1
            VStack(spacing: side * 0.1) {
                ZStack {
                    ZStack {
                        Circle().stroke(.gray.opacity(0.35), lineWidth: line)
                        Circle()
                            .trim(from: 0, to: Double(level ?? 0) / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        // The bolt sits in a gap cut from the ring: drawn over the green arc it would not read.
                        Circle()
                            .frame(width: side * 0.26, height: side * 0.26)
                            .offset(y: -side / 2)
                            .blendMode(.destinationOut)
                            .opacity(charging ? 1 : 0)
                    }
                    .compositingGroup()
                    Image(systemName: glyph)
                        .font(.system(size: side * 0.32))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: side * 0.16))
                        .foregroundStyle(.green)
                        .offset(y: -side / 2)
                        .opacity(charging ? 1 : 0)
                }
                .frame(width: side, height: side)
                Text(level.map { "\(approximate ? "~" : "")\($0)%" } ?? "–")
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

/// The sizes a widget declares, one list per widget so a test reads what the widget offers.
enum WidgetFamilies {
    static let deviceBattery: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
}

struct DeviceBatteryEntry: TimelineEntry {
    let date: Date
    /// What the app put on the shelf, or why there is nothing to read.
    let shelf: Result<Shelved<[WidgetDevice]>, any Error>
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
        content.containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var content: some View {
        switch entry.shelf {
        case .failure, .success(.appNotRunning): Message(glyph: "dot.radiowaves.left.and.right", text: "Open \(appName)")
        case .success(.running(let devices)): chosen(from: devices)
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
        let ring = BatteryRing(level: device.level?.percent, charging: false, approximate: device.level?.approximate ?? false, glyph: device.kind.symbol)
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
