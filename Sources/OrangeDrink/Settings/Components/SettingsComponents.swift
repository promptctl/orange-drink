import SwiftUI

// The parts every settings screen is built from (design-docs/README.md, Shared patterns).
// A screen adds its content and nothing else: its sections, its cards, its rows.

/// A coloured line-art icon, a bold white title, and an optional grey info line.
struct SettingsSectionHeader: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    var info: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color).accessibilityHidden(true)
                Text(title).font(.system(size: 17, weight: .bold))
            }
            if let info {
                Label(info, systemImage: "info.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        // One heading that reads as the title, with the info line as its hint.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(info ?? "")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded surface with a faint border, holding rows. Each row draws the hairline under itself,
/// inset from the left; the last one falls below the card's edge and is clipped, so dividers sit
/// only between rows.
struct SettingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.bottom, -1)
            .background(Color.veil(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.veil(0.1), lineWidth: 1))
    }
}

/// An optional muted icon tile, a bold title over a grey description, and a right-aligned control.
struct SettingRow<Control: View>: View {
    var icon: (symbol: String, color: Color)?
    let title: LocalizedStringKey
    var description: LocalizedStringKey?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                RoundedRectangle(cornerRadius: 7).fill(icon.color.opacity(0.25))
                    .frame(width: 28, height: 28)
                    .overlay { Image(systemName: icon.symbol).foregroundStyle(icon.color) }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.bold)
                if let description { Text(description).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(12)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 56) }
        .accessibilityElement(children: .contain)
    }
}

/// A grey circled "i" (or other glyph) that shows an explanation of the setting.
struct InfoButton: View {
    let text: Phrase
    var glyph = "info.circle"
    var label: Phrase = "Info"
    @Environment(\.appLanguage) private var language
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: glyph).foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .accessibilityLabel(label.text(in: language))
            .popover(isPresented: $showing) { PhraseText(text).padding(12).frame(width: 240) }
    }
}

/// One option of a pick-one list: a bold title over a grey description, and on the far right a green
/// check when chosen or an empty ring when not.
struct RadioRow: View {
    let title: Phrase
    let description: Phrase
    let isSelected: Bool
    let choose: () -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    PhraseText(title).fontWeight(.bold)
                    PhraseText(description).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityLabel(title.text(in: language))
        .accessibilityHint(description.text(in: language))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A dark rounded button showing the current value with ⌃⌄ on the right.
struct PopUpButton<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> Text

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: { title(option) }
            }
        } label: {
            HStack(spacing: 6) {
                title(selection)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.veil(0.1), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

/// The standard macOS switch, its "on" colour set by the screen.
struct AccentSwitch: View {
    @Binding var isOn: Bool
    let tint: Color
    let label: LocalizedStringKey

    var body: some View {
        Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(tint)
    }
}

/// A row of capsules for picking one: the selected one filled with the accent in bold white, the rest dark grey.
struct SegmentedPills<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let accent: Color
    let title: (Value) -> Phrase
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    PhraseText(title(option)).fontWeight(selected ? .bold : .regular)
                        .foregroundStyle(selected ? .white : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(selected ? accent : Color.veil(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option).text(in: language))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Near-black (near-white in a light appearance) with large, soft, low-opacity glows of colour: decoration that tracks no data.
struct SettingsBackground: View {
    var glow: Color = .green
    var glowCenter: UnitPoint = .topTrailing

    var body: some View {
        ZStack {
            AdaptiveColor(light: Color(white: 0.96), dark: Color(white: 0.06))
            RadialGradient(colors: [glow.opacity(0.18), .clear], center: glowCenter, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
