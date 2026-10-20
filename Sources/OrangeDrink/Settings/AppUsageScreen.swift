import AppKit
import OSLog
import SwiftUI

/// design-docs/app-usage.md: the status line, the range pills, the Right Now and Top Drainers cards, the insights,
/// and the Top Energy Consumers list, all read from the one ranking.
struct AppUsageScreen: View {
    let appEnergy: Result<AppEnergyHistory, any Error>
    @State private var range = AppUsageRange.day
    @State private var loaded: Result<AppUsageRanking, any Error>?
    @State private var detail: AppDetailSheet.Subject?
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "app-energy")

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch loaded {
            case nil: EmptyView()
            case .failure: PhraseText("App energy history is unavailable. Quit and reopen the app.").foregroundStyle(.secondary)
            case .success(let ranking):
                HStack {
                    PhraseText(ranking.statusText).foregroundStyle(.secondary)
                    Spacer()
                    SegmentedPills(selection: $range, options: AppUsageRange.allCases, accent: .indigo, title: \.title)
                }
                HStack(alignment: .top, spacing: 16) {
                    RightNowCard(ranking: ranking)
                    TopDrainersCard(ranking: ranking)
                }
                InsightsSection(insights: ranking.insights, seeDetails: { detail = AppDetailSheet.Subject(app: $0, ranking: ranking) })
                ConsumersSection(consumers: ranking.apps, open: { detail = AppDetailSheet.Subject(app: $0, ranking: ranking) })
            }
        }
        .padding(24)
        .background(SettingsBackground(glow: .indigo, glowCenter: .top))
        .sheet(item: $detail) { AppDetailSheet(subject: $0) }
        .task(id: Refresh(range: range, revision: (try? appEnergy.get())?.changes.revision)) {
            let ranking = Result { try appEnergy.get().ranking(range: range) }
            // A pill tapped again while this ran has cancelled it; its range is no longer the one selected.
            guard !Task.isCancelled else { return }
            loaded = ranking
            if case .failure(let error)? = loaded { Self.log.error("app usage unreadable: \(String(describing: error), privacy: .public)") }
        }
    }

    private struct Refresh: Equatable { let range: AppUsageRange; let revision: Int? }
}

private struct RightNowCard: View {
    let ranking: AppUsageRanking

    var body: some View {
        RankingCard(tint: .clear, border: Color.veil(0.1)) {
            HStack {
                Label { PhraseText("RIGHT NOW").font(.caption.weight(.semibold)) } icon: { Image(systemName: "bolt.circle.fill") }
                    .foregroundStyle(.secondary)
                Spacer()
                if ranking.lastSampleAt != nil {
                    // The age moves with the clock, not with the writes.
                    TimelineView(.everyMinute) { context in
                        if let age = ranking.rightNowAge(now: context.date) {
                            PhraseText(age).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            RankedRows(shares: ranking.rightNow, highlightFirst: false)
        }
    }
}

private struct TopDrainersCard: View {
    let ranking: AppUsageRanking

    var body: some View {
        RankingCard(tint: Color.orange.opacity(0.1), border: Color.orange.opacity(0.5)) {
            Label { PhraseText("TOP DRAINERS · \(ranking.range.capitals)").font(.caption.weight(.semibold)) } icon: { Image(systemName: "flame.fill") }
                .foregroundStyle(.orange)
            RankedRows(shares: ranking.drainers, highlightFirst: true)
        }
    }
}

private struct RankingCard<Content: View>: View {
    let tint: Color
    let border: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.veil(0.05), in: RoundedRectangle(cornerRadius: 12))
            .background(tint, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
    }
}

/// design-docs/app-usage.md "Top Energy Consumers": every tracked app, its trend across the range, its share.
private struct ConsumersSection: View {
    let consumers: [AppConsumer]
    let open: (AppIdentity) -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        if !consumers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label { PhraseText("TOP ENERGY CONSUMERS").font(.caption.weight(.semibold)) } icon: { Image(systemName: "list.bullet") }
                    .foregroundStyle(.secondary)
                LazyVStack(spacing: 0) {
                    ForEach(Array(consumers.enumerated()), id: \.element.share.app) { index, consumer in
                        if index > 0 { Divider() }
                        Button { open(consumer.share.app) } label: { row(consumer) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .background(Color.veil(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.veil(0.1), lineWidth: 1))
            }
        }
    }

    private func row(_ consumer: AppConsumer) -> some View {
        let app = consumer.share.app
        return HStack(spacing: 12) {
            Image(nsImage: AppIcon.image(for: app)).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(app.bundleID ?? app.key).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 180, alignment: .leading)
            Sparkline(values: consumer.slices.map(Double.init)).frame(maxWidth: .infinity).frame(height: 32).accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ShareFormat.text(percent: consumer.share.share * 100, locale: language.locale)).fontWeight(.bold)
                PhraseText("of total").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A thin red line over a faint red fill, scaled to its own highest point.
private struct Sparkline: View {
    let values: [Double]
    private let stroke = 1.5

    var body: some View {
        GeometryReader { box in
            // Drawn inside a stroke-wide margin so a peak or a flat baseline at the edge is not half cut off.
            let width = box.size.width, height = box.size.height - stroke * 2
            let top = values.max() ?? 0
            let points = values.enumerated().map { index, value in
                CGPoint(x: width * Double(index) / Double(max(values.count - 1, 1)),
                        y: stroke + height * (top > 0 ? 1 - value / top : 1))
            }
            ZStack {
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: stroke + height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: stroke + height))
                    path.closeSubpath()
                }
                .fill(Color.red.opacity(0.15))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Color.red, style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
            }
        }
    }
}

enum AppPalette {
    static let colors: [Color] = [.teal, .red, .purple, .pink, .blue, .mint, .yellow, .cyan]

    static func color(for app: AppIdentity) -> Color { colors[AppColor.index(for: app, of: colors.count)] }
}

/// The app's own icon, or the generic one for an executable with no bundle.
enum AppIcon {
    @MainActor static func image(for app: AppIdentity) -> NSImage {
        let workspace = NSWorkspace.shared
        if let bundleID = app.bundleID, let url = workspace.urlForApplication(withBundleIdentifier: bundleID) { return workspace.icon(forFile: url.path) }
        return workspace.icon(forFile: app.key)
    }
}
