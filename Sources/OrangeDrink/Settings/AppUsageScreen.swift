import AppKit
import OSLog
import SwiftUI

/// design-docs/app-usage.md: the status line, the range pills, and the Right Now and Top Drainers cards.
/// The insights and the Top Energy Consumers list read the same ranking.
struct AppUsageScreen: View {
    let appEnergy: Result<AppEnergyHistory, any Error>
    @State private var range = AppUsageRange.day
    @State private var loaded: Result<AppUsageRanking, any Error>?
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
            }
        }
        .padding(24)
        .background(SettingsBackground(glow: .indigo, glowCenter: .top))
        .task(id: Refresh(range: range, revision: (try? appEnergy.get())?.changes.revision)) {
            loaded = Result { try appEnergy.get().ranking(range: range) }
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

/// A ranked top-five list: rank, icon, name over a bar as long as the app's share is next to the longest, share.
private struct RankedRows: View {
    let shares: [AppShare]
    let highlightFirst: Bool
    @Environment(\.appLanguage) private var language

    var body: some View {
        if shares.isEmpty {
            PhraseText("Collecting app energy — rankings appear after a few minutes of use.").foregroundStyle(.secondary)
        } else {
            let longest = shares.map(\.share).max() ?? 1
            VStack(spacing: 10) {
                ForEach(Array(shares.enumerated()), id: \.element.app) { index, entry in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 14)
                        Image(nsImage: AppIcon.image(for: entry.app)).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.app.name).lineLimit(1)
                            GeometryReader { bar in
                                Capsule().fill(AppPalette.color(for: entry.app))
                                    .frame(width: bar.size.width * (longest > 0 ? entry.share / longest : 0), height: 4)
                            }
                            .frame(height: 4)
                        }
                        Text(ShareFormat.text(percent: entry.share * 100, locale: language.locale)).fontWeight(.bold)
                            .foregroundStyle(highlightFirst && index == 0 ? .orange : .primary)
                    }
                    .accessibilityElement(children: .combine)
                }
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
