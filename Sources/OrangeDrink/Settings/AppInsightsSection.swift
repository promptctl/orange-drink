import AppKit
import SwiftUI

/// design-docs/app-usage.md "Insights": a card per finding, each with a way to look closer and a way to act.
struct InsightsSection: View {
    let insights: [AppInsight]
    let seeDetails: (AppIdentity) -> Void

    var body: some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label { PhraseText("INSIGHTS").font(.caption.weight(.semibold)) } icon: { Image(systemName: "sparkle").foregroundStyle(.yellow) }
                    .foregroundStyle(.secondary)
                ForEach(insights) { insight in
                    InsightCard(insight: insight, seeDetails: { seeDetails(insight.app) })
                }
            }
        }
    }
}

private struct InsightCard: View {
    let insight: AppInsight
    let seeDetails: () -> Void
    @Environment(\.appLanguage) private var language

    private var dominating: Bool {
        if case .dominating = insight { true } else { false }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: dominating ? "flame.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 28)).foregroundStyle(dominating ? .orange : .yellow).frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(nsImage: AppIcon.image(for: insight.app)).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                    PhraseText(insight.heading()).fontWeight(.semibold)
                }
                PhraseText(insight.text(locale: language.locale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    InsightButton(title: "See details", icon: "chart.bar.fill", tint: dominating ? .orange : nil, action: seeDetails)
                    QuitButton(app: insight.app, tint: nil)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.veil(0.05), in: RoundedRectangle(cornerRadius: 12))
        .background(dominating ? Color.orange.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dominating ? Color.orange.opacity(0.5) : Color.veil(0.1), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A small outlined button; `tint` fills it, nil leaves it grey.
private struct InsightButton: View {
    let title: Phrase
    let icon: String
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { PhraseText(title) } icon: { Image(systemName: icon) }
                .font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(tint ?? .secondary)
                .background(tint?.opacity(0.15) ?? .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint?.opacity(0.5) ?? Color.veil(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Quits the app the insight is about; greyed out when nothing of it was running as of the last reload.
struct QuitButton: View {
    let app: AppIdentity
    let tint: Color?

    var body: some View {
        let running = AppQuitter.running(app)
        InsightButton(title: "Quit", icon: "xmark.circle", tint: tint) { AppQuitter.quit(running) }
            .disabled(running.isEmpty)
    }
}

/// [LAW:effects-at-boundaries] The one place an insight acts on a process.
enum AppQuitter {
    /// An app is the running instances of its bundle id; with no bundle id its key is a bundle's or an executable's path.
    @MainActor static func running(_ app: AppIdentity) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            matches(app, bundleID: $0.bundleIdentifier, bundlePath: $0.bundleURL?.path, executablePath: $0.executableURL?.path)
        }
    }

    static func matches(_ app: AppIdentity, bundleID: String?, bundlePath: String?, executablePath: String?) -> Bool {
        if let wanted = app.bundleID { return bundleID == wanted }
        return bundlePath == app.key || executablePath == app.key
    }

    /// Asks politely: the app may offer to save, as it would for Cmd-Q.
    @MainActor static func quit(_ running: [NSRunningApplication]) {
        for instance in running { instance.terminate() }
    }
}

/// What the ranking knows about one app: reached from an insight's See details.
struct AppDetailSheet: View {
    /// The ranking as it was when the sheet opened, so a reload behind it cannot change or blank it.
    struct Subject: Identifiable {
        let app: AppIdentity
        let ranking: AppUsageRanking
        var id: String { app.key }
    }

    let subject: Subject
    private var app: AppIdentity { subject.app }
    private var ranking: AppUsageRanking { subject.ranking }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: AppIcon.image(for: app)).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(app.name).font(.title3.weight(.semibold))
                    if let bundleID = app.bundleID { Text(bundleID).font(.caption).foregroundStyle(.secondary) }
                }
            }
            figure("Share of energy in the last \(ranking.range.title)", of: ranking.apps)
            figure("Share of energy right now", of: ranking.latest)
            HStack {
                QuitButton(app: app, tint: nil)
                Spacer()
                Button { dismiss() } label: { PhraseText("Close") }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 360)
    }

    private func figure(_ title: Phrase, of shares: [AppShare]) -> some View {
        HStack {
            PhraseText(title).foregroundStyle(.secondary)
            Spacer()
            Text(shares.first { $0.app == app }.map { ShareFormat.text(percent: $0.share * 100, locale: language.locale) } ?? "—").fontWeight(.bold)
        }
    }
}
