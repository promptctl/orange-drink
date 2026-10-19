import SwiftUI

extension KeyCombo.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = [(NSEvent.ModifierFlags.control, Self.control), (.option, .option), (.shift, .shift), (.command, .command)]
            .filter { flags.contains($0.0) }.reduce([]) { $0.union($1.1) }
    }
}

extension RecordedKey {
    init(_ event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), character: event.charactersIgnoringModifiers?.first,
                  modifiers: KeyCombo.Modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }
}

/// A dark rounded field showing a shortcut. Clicking it listens for the next key press, which goes to
/// `record`; Escape, or clicking it again, stops without recording.
struct KeyRecorder: View {
    let display: String
    let label: LocalizedStringKey
    let record: (RecordedKey) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording.toggle() } label: {
            Text(recording ? "Type shortcut…" : display)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(recording ? Color.accentColor : Color.primary)
                .frame(width: 130)
                .padding(.vertical, 5)
                .background(Color.veil(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(display)
        .accessibilityHint("Click, then press the new shortcut")
        .onChange(of: recording) { _, listening in listening ? listen() : stopListening() }
        .onDisappear { recording = false }
    }

    private func listen() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape (key code 53) gives up; any other key is the shortcut, and is not typed into the window.
            let escape = event.keyCode == 53
            MainActor.assumeIsolated {
                if !escape { record(RecordedKey(event)) }
                recording = false
            }
            return nil
        }
    }

    private func stopListening() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }
}
