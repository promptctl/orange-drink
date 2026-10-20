import SwiftUI

/// A ranked top-five list: rank, icon, name over a bar as long as the app's share is next to the longest, share.
struct RankedRows: View {
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
