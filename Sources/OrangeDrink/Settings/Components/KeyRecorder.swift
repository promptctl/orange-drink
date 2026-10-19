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

/// A dark rounded field showing a shortcut; while it is recording it asks for the next key press.
/// Which recorder is recording is the screen's to say, so two can never be at once.
struct KeyRecorder: View {
    let display: String
    let label: LocalizedStringKey
    let isRecording: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Text(isRecording ? "Type shortcut…" : display)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .frame(width: 130)
                .padding(.vertical, 5)
                .background(Color.veil(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(display)
        .accessibilityHint("Click, then press the new shortcut")
    }
}

/// While active, the next key press goes to `onKey` instead of the window, and Escape to `onCancel`.
private struct KeyCapture: ViewModifier {
    let isActive: Bool
    let onKey: (RecordedKey) -> Void
    let onCancel: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { _, active in active ? listen() : stop() }
            .onDisappear(perform: stop)
    }

    private func listen() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape (key code 53) gives up; any other key is the shortcut, and is not typed into the window.
            MainActor.assumeIsolated { event.keyCode == 53 ? onCancel() : onKey(RecordedKey(event)) }
            return nil
        }
    }

    private func stop() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }
}

extension View {
    func keyCapture(isActive: Bool, onKey: @escaping (RecordedKey) -> Void, onCancel: @escaping () -> Void) -> some View {
        modifier(KeyCapture(isActive: isActive, onKey: onKey, onCancel: onCancel))
    }
}
