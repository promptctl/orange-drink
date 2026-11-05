import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

/// One connected display, as the cover is placed on it.
struct CoverDisplay: Equatable {
    /// The whole display, menu bar and Dock included, which the cover fills.
    let frame: CGRect
    /// The display System Settings › Displays marks as main, whose cover takes keyboard focus.
    let isPrimary: Bool

    /// [LAW:effects-at-boundaries] The displays connected now, as AppKit says. The first of
    /// `NSScreen.screens` is the main display, the one with the menu bar.
    @MainActor static func connected() -> [CoverDisplay] {
        NSScreen.screens.enumerated().map { CoverDisplay(frame: $0.element.frame, isPrimary: $0.offset == 0) }
    }
}

/// Why the cover came down, as its log line says it.
enum CoverEnd: String {
    case dismissButton = "Dismiss"
    case escape = "Esc"
    /// The adapter was connected under a low alert, or disconnected under a charged one: the alert has been answered.
    case adapterConnected = "adapter connected"
    case adapterDisconnected = "adapter disconnected"

    /// [LAW:one-source-of-truth] The one rule for what answers an alert: the adapter connected answers
    /// a low alert, disconnected a charged one. nil when none of `changes` answers `kind`.
    init?(answering kind: Alert.Kind, in changes: [BatteryEvent]) {
        let answers = changes.compactMap { change -> CoverEnd? in
            switch (change, kind) {
            case (.plugged, .low): .adapterConnected
            case (.unplugged, .charged): .adapterDisconnected
            case (.plugged, .charged), (.unplugged, .low), (.levelChanged, _): nil
            }
        }
        guard let answer = answers.first else { return nil }
        self = answer
    }
}

/// The cover's window on one display: it takes keyboard focus, and the clicks on it land on it.
final class CoverPanel: OverlayPanel {
    /// The keys and clicks the cover ignores until it accepts input.
    private static let input: Set<NSEvent.EventType> = [
        .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]

    /// The view the panel hosts, in the language it was handed.
    let hosted: AnyView
    private let accepting: () -> Bool
    private let onDismiss: (CoverEnd) -> Void

    init(_ content: CoverContent, language: AppLanguage, frame: CGRect, accepting: @escaping () -> Bool, onDismiss: @escaping (CoverEnd) -> Void) {
        self.accepting = accepting
        self.onDismiss = onDismiss
        // A press that never passes `sendEvent` — VoiceOver's, Switch Control's — is held off here.
        hosted = AnyView(CoverView(content: content, onDismiss: { if accepting() { onDismiss(.dismissButton) } }).speaking(language))
        super.init(frame: frame, level: .cover, hosting: FirstClickHostingView(rootView: hosted))
        hasShadow = false
    }

    /// Takes the click that makes its panel key, so Dismiss on a display without focus is one click.
    private final class FirstClickHostingView: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// A fresh press of Esc alone: a held Esc that began before the cover, or a chord with Esc, is not one.
    private static func isEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && Int(event.keyCode) == kVK_Escape && !event.isARepeat
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    override var canBecomeKey: Bool { true }

    /// [LAW:single-enforcer] The one place the cover's input is held off: a key or click reaches the
    /// cover only once it accepts input, and Esc is read here, so it is held off with the rest.
    /// A Command chord reaches the key window before `sendEvent`; held off here, it never reaches the app's menu either.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        accepting() ? super.performKeyEquivalent(with: event) : true
    }

    override func sendEvent(_ event: NSEvent) {
        // Esc closes this panel and drops the controller's hold on it while AppKit is still in this call.
        withExtendedLifetime(self) { dispatch(event) }
    }

    private func dispatch(_ event: NSEvent) {
        guard accepting() || !Self.input.contains(event.type) else { return }
        if Self.isEscape(event) { onDismiss(.escape) } else { super.sendEvent(event) }
    }
}

/// The full-screen alert up, on every display: a new one replaces it, and Dismiss or Esc on any
/// display clears every display.
///
/// [LAW:single-enforcer] `up` is the only record of the cover: its content, its panels, and whether
/// it accepts input yet. Panels read that record, so one built for a display connected later is
/// armed exactly when the cover is.
@MainActor final class CoverController {
    /// How long a new cover ignores keys and clicks, so a keystroke already on its way does not dismiss it unread.
    nonisolated static let unarmedFor: Duration = .seconds(1)

    @MainActor private final class Cover {
        /// The alert up, whose kind decides the adapter change that answers it.
        let alert: Alert
        let content: CoverContent
        var accepting = false
        var panels: [CoverPanel] = []
        var arming: Task<Void, any Error>?

        init(alert: Alert, content: CoverContent) { self.alert = alert; self.content = content }

        func close() { arming?.cancel(); panels.forEach { $0.close() } }
    }

    private let language: AppLanguageModel
    private let timekeeper: any Timekeeper
    private let displays: @MainActor () -> [CoverDisplay]
    private let orderFront: @MainActor (CoverPanel, _ key: Bool) -> Void
    private let log: Logger
    private var up: Cover?
    nonisolated(unsafe) private var following: Task<Void, Never>?

    /// [LAW:effects-at-boundaries] `orderFront` puts a built panel on the screen, making it key when
    /// asked; it has no default, so a test holds the panels and asserts on them without showing them.
    init(language: AppLanguageModel, orderFront: @escaping @MainActor (CoverPanel, _ key: Bool) -> Void,
         timekeeper: any Timekeeper = SystemTimekeeper(), displays: @escaping @MainActor () -> [CoverDisplay] = CoverDisplay.connected,
         log: Logger) {
        self.language = language
        self.orderFront = orderFront
        self.timekeeper = timekeeper
        self.displays = displays
        self.log = log
    }

    deinit { following?.cancel() }

    var shown: CoverContent? { up?.content }
    /// The cover's panels, one per display it is drawn on.
    var shownPanels: [CoverPanel] { up?.panels ?? [] }
    /// Whether the cover up takes keys and clicks yet.
    var shownAccepting: Bool? { up?.accepting }

    /// Puts up the cover for `alert`, which `reading` fired.
    func show(_ alert: Alert, reading: BatteryReading) {
        take(down: "replaced")
        let content = CoverContent(alert, reading: reading)
        let cover = Cover(alert: alert, content: content)
        up = cover
        draw(cover)
        log.info("cover shown on \(cover.panels.count) displays: \(content.headline.english, privacy: .private)")
    }

    /// The displays changed: the cover up is drawn again on the displays connected now.
    func screensChanged() {
        guard let up else { return }
        draw(up)
        log.info("cover drawn again on \(up.panels.count) displays: \(up.content.headline.english, privacy: .private)")
    }

    /// Feeds the controller each change of displays, for as long as it lives.
    func follow(layout: AsyncStream<Void>) {
        following?.cancel()
        following = Task { [weak self] in
            for await _ in layout {
                guard let self else { return }
                self.screensChanged()
            }
        }
    }

    func dismiss(_ end: CoverEnd) { take(down: "dismissed: \(end.rawValue)") }

    /// The changes a new reading of the Mac's battery brought. The adapter change that answers the
    /// cover's alert takes it down; a low alert fired with the adapter already connected waits for
    /// Dismiss or Esc, as no change answers it.
    func observe(_ changes: [BatteryEvent]) {
        if let up, let answer = CoverEnd(answering: up.alert.kind, in: changes) { dismiss(answer) }
    }

    /// One panel per display connected now, each reading the cover's own `accepting`.
    private func draw(_ cover: Cover) {
        cover.panels.forEach { $0.close() }
        let displays = displays()
        cover.panels = displays.map { display in
            CoverPanel(cover.content, language: language.value, frame: display.frame, accepting: { [weak cover] in cover?.accepting == true },
                       onDismiss: { [weak self] in self?.dismiss($0) })
        }
        for (panel, display) in zip(cover.panels, displays) { orderFront(panel, display.isPrimary) }
        // [LAW:no-ambient-temporal-coupling] The unarmed second starts when the cover is first seen, so
        // one fired with no display holds input off once a display shows it. The arming belongs to the
        // cover, which cancels it on any dismissal or replacement.
        if cover.arming == nil && !cover.panels.isEmpty {
            cover.arming = Task { [timekeeper] in
                try await timekeeper.sleep(for: Self.unarmedFor)
                try Task.checkCancellation()
                cover.accepting = true
            }
        }
        // [LAW:no-silent-failure] With every display gone the cover is kept, and the next display connected draws it.
        if displays.isEmpty { log.error("no display to draw the cover on: \(cover.content.headline.english, privacy: .private)") }
    }

    private func take(down why: String) {
        if let up {
            log.info("cover \(why, privacy: .public): \(up.content.headline.english, privacy: .private)")
            up.close()
        }
        up = nil
    }
}
