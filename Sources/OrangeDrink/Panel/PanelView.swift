import SwiftUI

/// The panel the status item opens: stacked rounded cards on a dark ground.
struct PanelView: View {
    let state: BatteryModel.State
    let sections: PanelSections

    var body: some View {
        VStack(spacing: 10) {
            switch state {
            case .known(let reading?): ChargeCardView(card: ChargeCard(reading))
            case .unknown: PanelNote("Reading the battery…")
            case .known(nil): PanelNote("This Mac has no battery.")
            case .ended: PanelNote("Battery readings stopped. Quit and reopen the app.")
            }
            CollapsibleCard(title: "Battery Information", symbol: "info.circle.fill", symbolColor: .blue,
                            section: .batteryInformation, sections: sections) {
                if case .known(let reading?) = state { BatteryInformationView(info: BatteryInformation(reading)) }
            }
            Button("Quit \(appName)") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 330)
        .background(.black.opacity(0.85))
        .preferredColorScheme(.dark)
    }
}

private struct PanelNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card() }
}

extension View {
    /// The panel's card: a rounded surface with a thin border.
    func card() -> some View {
        padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
    }
}

struct ChargeCardView: View {
    let card: ChargeCard

    private var tint: Color {
        switch card.tint {
        case .neutral, .green: .green
        case .orange: .orange
        case .red: .red
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(card.percent).font(.system(size: 40, weight: .bold))
                        Text(card.unit).font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundStyle(tint)
                    HStack(spacing: 4) {
                        if card.status == .charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                        Text(card.status.title)
                    }
                    .font(.callout)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(card.estimateCaption).font(.caption2).foregroundStyle(.secondary)
                    Text(card.estimate).font(.title3.bold())
                }
            }
            ProgressBar(fraction: card.progress, tint: tint)
        }
        .card()
    }
}

/// A full-width rounded bar on a dark track, with faint ticks at 25% and 50%.
private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint).frame(width: bar.size.width * fraction)
                ForEach([0.25, 0.5], id: \.self) { mark in
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1).offset(x: bar.size.width * mark)
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

struct CollapsibleCard<Content: View>: View {
    let title: String
    let symbol: String
    let symbolColor: Color
    let section: PanelSections.Section
    let sections: PanelSections
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            Button { sections.toggle(section) } label: {
                HStack {
                    Image(systemName: symbol).foregroundStyle(symbolColor)
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: sections.isOpen(section) ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if sections.isOpen(section) { content() }
        }
        .card()
    }
}
