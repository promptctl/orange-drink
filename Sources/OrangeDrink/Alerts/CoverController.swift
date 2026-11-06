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

/// An app other than this one, frontmost before the cover came up, which it hands focus back to.
struct FrontApp: Equatable {
    let pid: pid_t
    let name: String
}

/// How a VoiceOver announcement meets the speech under way.
enum Announcement: Equatable {
    /// Cuts off what VoiceOver is reading, as the cover appearing does.
    case interrupting
    /// Waits for what VoiceOver is reading, so a level that wavers never cuts it off.
    case afterCurrent
}

/// [LAW:effects-at-boundaries] What the cover does to the rest of the Mac's focus: the app in front,
/// the app's own windows, and VoiceOver. None has a default, so a test records each instead of acting.
struct CoverFocus {
    /// The app in front now; nil when it is this one.
    let frontmost: @MainActor () -> FrontApp?
    let activate: @MainActor (FrontApp) -> Void
    /// Gives up active status, for the app macOS picks next.
    let deactivate: @MainActor () -> Void
    /// Closes the panel, Settings, and any other window of this app that is not an alert's.
    let closeAppWindows: @MainActor () -> Void
    /// Says the text to VoiceOver.
    let announce: @MainActor (String, Announcement) -> Void

    /// A window of this app the cover closes: a visible titled one, Settings among them. The menu
    /// bar's and the alerts' are untitled, and an alert's own panel is never closed.
    @MainActor static func closesUnderCover(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && !(window is OverlayPanel)
    }

    @MainActor static func live(panel: any Panel, log: Logger) -> CoverFocus {
        CoverFocus(
            frontmost: {
                NSWorkspace.shared.frontmostApplication.flatMap { app in
                    app.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil
                        : FrontApp(pid: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)")
                }
            },
            activate: { app in
                // [LAW:no-silent-failure] An app that quit while the cover was up has nothing to take focus, and the log says so.
                guard let running = NSRunningApplication(processIdentifier: app.pid), running.activate() else {
                    return log.error("cover could not return focus to \(app.name, privacy: .public): it is not running or refused")
                }
            },
            deactivate: { NSApp.deactivate() },
            closeAppWindows: {
                panel.close()
                NSApp.windows.filter(closesUnderCover).forEach { $0.close() }
            },
            announce: { text, kind in
                // High interrupts and cannot be interrupted; low waits its turn. Medium interrupts too, so it is not used.
                let priority: NSAccessibilityPriorityLevel = switch kind { case .interrupting: .high; case .afterCurrent: .low }
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: text, .priority: priority.rawValue])
            })
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
        let answer = changes.lazy.compactMap { change -> CoverEnd? in
            switch (change, kind) {
            case (.plugged, .low): .adapterConnected
            case (.unplugged, .charged): .adapterDisconnected
            case (.plugged, .charged), (.unplugged, .low), (.levelChanged, _): nil
            }
        }.first
        guard let answer else { return nil }
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

    init(_ shown: CoverShown, language: AppLanguage, frame: CGRect, isPrimary: Bool, accepting: @escaping () -> Bool,
         onDismiss: @escaping (CoverEnd) -> Void) {
        self.accepting = accepting
        self.onDismiss = onDismiss
        // A press that never passes `sendEvent` — VoiceOver's, Switch Control's — is held off here.
        hosted = AnyView(CoverView(shown: shown, takesVoiceOverFocus: isPrimary, onDismiss: { if accepting() { onDismiss(.dismissButton) } })
            .speaking(language))
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

    /// [LAW:types-are-the-program] Behind the lock screen or the screen saver the app in front is
    /// macOS's own, so the app to return to is read only once the cover is seen.
    private enum ReturnTo {
        case unread
        /// nil when this app was in front.
        case read(FrontApp?)
    }

    @MainActor private final class Cover {
        /// The alert up, whose kind decides the adapter change that answers it.
        let alert: Alert
        let shown: CoverShown
        /// The app in front when the first of a run of covers was first seen; a cover replacing this one takes it over.
        var returnTo: ReturnTo
        var accepting = false
        /// One panel per display it is drawn on, with the display it fills.
        var drawn: [(panel: CoverPanel, display: CoverDisplay)] = []
        var panels: [CoverPanel] { drawn.map(\.panel) }
        /// The panel on the primary display, which holds keyboard focus.
        var keyPanel: CoverPanel? { drawn.first { $0.display.isPrimary }?.panel }
        var arming: Task<Void, any Error>?

        init(alert: Alert, content: CoverContent, returnTo: ReturnTo) {
            self.alert = alert
            shown = CoverShown(content)
            self.returnTo = returnTo
        }

        func close() { arming?.cancel(); panels.forEach { $0.close() } }
    }

    private let language: AppLanguageModel
    private let timekeeper: any Timekeeper
    private let displays: @MainActor () -> [CoverDisplay]
    private let orderFront: @MainActor (CoverPanel, _ key: Bool) -> Void
    private let focus: CoverFocus
    private let log: Logger
    private var up: Cover?
    /// What hides the screen now. It outlives any one cover, so a cover shown behind the lock screen starts unarmed.
    /// nil until the first answer arrives, and a screen not yet known to be seen counts as hidden.
    private var hidden: Set<ScreenHider>?
    nonisolated(unsafe) private var following: [Task<Void, Never>] = []

    /// [LAW:effects-at-boundaries] `orderFront` puts a built panel on the screen, making it key when
    /// asked; it and `focus` have no default, so a test holds what they are handed without acting on the Mac.
    init(language: AppLanguageModel, orderFront: @escaping @MainActor (CoverPanel, _ key: Bool) -> Void, focus: CoverFocus,
         timekeeper: any Timekeeper = SystemTimekeeper(), displays: @escaping @MainActor () -> [CoverDisplay] = CoverDisplay.connected,
         log: Logger) {
        self.language = language
        self.orderFront = orderFront
        self.focus = focus
        self.timekeeper = timekeeper
        self.displays = displays
        self.log = log
    }

    deinit { following.forEach { $0.cancel() } }

    var shown: CoverContent? { up?.shown.content }
    /// The cover's panels, one per display it is drawn on.
    var shownPanels: [CoverPanel] { up?.panels ?? [] }
    /// Whether the cover up takes keys and clicks yet.
    var shownAccepting: Bool? { up?.accepting }
    /// What every display's view of the cover up reads.
    var shownModel: CoverShown? { up?.shown }

    /// Puts up the cover for `alert`, which `reading` fired.
    ///
    /// [LAW:dataflow-not-control-flow] The app to return to moves from a replaced cover to its
    /// replacement, and a replaced cover leaves focus alone: only a dismissal hands it on.
    func show(_ alert: Alert, reading: BatteryReading) {
        let returnTo = up.map(\.returnTo) ?? .unread
        if let replaced = up {
            log.info("cover replaced: \(replaced.shown.content.headline.english, privacy: .private)")
            replaced.close()
        }
        let content = CoverContent(alert, reading: reading)
        let cover = Cover(alert: alert, content: content, returnTo: returnTo)
        up = cover
        focus.closeAppWindows()
        log.info("cover shown: \(content.headline.english, privacy: .private)")
        draw(cover)
    }

    /// A window of this app became key. While the cover is up only the cover may be: any other is
    /// closed, and the cover takes focus back.
    func windowCameForward(isCover: Bool) {
        guard let up, !isCover else { return }
        focus.closeAppWindows()
        up.keyPanel.map { orderFront($0, true) }
        log.info("cover closed app windows: another came forward")
    }

    /// What hides the screen changed. Hidden, the cover takes no input; seen again, it takes focus
    /// back and holds input off for a fresh `unarmedFor`.
    func screen(hidden now: Set<ScreenHider>) {
        guard now != hidden else { return }
        // The first answer that the screen is seen is not seeing it again.
        let seenAgain = now.isEmpty && hidden != nil
        hidden = now
        guard let up else { return }
        if seenAgain, let key = up.keyPanel {
            orderFront(key, true)
            log.info("cover takes focus again: screen seen")
        }
        arm(up)
    }

    /// The displays changed: the cover up is drawn again on the displays connected now.
    func screensChanged() {
        guard let up else { return }
        draw(up)
    }

    /// Feeds the controller each change of what hides the screen and of displays, for as long as it lives.
    func follow(screen hiders: AsyncStream<Set<ScreenHider>>, layout: AsyncStream<Void>) {
        following.forEach { $0.cancel() }
        following = [
            Task { [weak self] in
                for await hidden in hiders {
                    guard let self else { return }
                    self.screen(hidden: hidden)
                }
            },
            Task { [weak self] in
                for await _ in layout {
                    guard let self else { return }
                    self.screensChanged()
                }
            },
        ]
    }

    func dismiss(_ end: CoverEnd) { take(down: "dismissed: \(end.rawValue)") }

    /// A new reading of the Mac's battery and the changes it brought. The adapter change that answers
    /// the cover's alert takes it down; a low alert fired with the adapter already connected waits for
    /// Dismiss or Esc, as no change answers it. Otherwise the cover says what the reading says, in
    /// place: it is not drawn or armed again, and its sound is not played again. A new headline in
    /// sight is told to VoiceOver after what it is reading, so a level that wavers never cuts it off;
    /// a change to the second line alone is not told.
    func observe(_ reading: BatteryReading, changes: [BatteryEvent]) {
        guard let up else { return }
        if let answer = CoverEnd(answering: up.alert.kind, in: changes) { return dismiss(answer) }
        let was = up.shown.content.headline
        guard up.shown.show(CoverContent(up.alert, reading: reading)) else { return }
        // Out of sight, the announcement when it is seen again carries the level then.
        let heard = inSight(up) && up.shown.content.headline != was
        if heard { announce(up, .afterCurrent) }
        log.info("cover follows the battery: \(was.english, privacy: .private) → \(up.shown.content.headline.english, privacy: .private)\(heard ? ", announced to VoiceOver" : "", privacy: .public)")
    }

    /// [LAW:one-source-of-truth] The cover is in sight when it is on a display and nothing hides the screen.
    private func inSight(_ cover: Cover) -> Bool { !cover.panels.isEmpty && hidden == [] }

    /// Tells VoiceOver what the cover says: its headline, then its second line.
    private func announce(_ cover: Cover, _ kind: Announcement) {
        let content = cover.shown.content, language = language.value
        focus.announce([content.headline, content.subline].compactMap { $0?.resolve(in: language) }.joined(separator: ". "), kind)
    }

    /// One panel per display connected now, each reading the cover's own `accepting`.
    private func draw(_ cover: Cover) {
        cover.panels.forEach { $0.close() }
        let displays = displays()
        cover.drawn = displays.map { display in
            (CoverPanel(cover.shown, language: language.value, frame: display.frame, isPrimary: display.isPrimary,
                        accepting: { [weak cover] in cover?.accepting == true }, onDismiss: { [weak self] in self?.dismiss($0) }),
             display)
        }
        cover.drawn.forEach { orderFront($0.panel, $0.display.isPrimary) }
        log.info("cover drawn on \(displays.count) displays")
        arm(cover)
        // [LAW:no-silent-failure] With every display gone the cover is kept, and the next display connected draws it.
        if displays.isEmpty { log.error("no display to draw the cover on: \(cover.shown.content.headline.english, privacy: .private)") }
    }

    /// [LAW:single-enforcer] The one place arming starts or stops, from two facts: the cover is on a
    /// display, and nothing hides the screen.
    ///
    /// [LAW:no-ambient-temporal-coupling] The unarmed second starts when the cover is seen, so one
    /// fired with no display, or behind the lock screen, holds input off once it is seen; a display
    /// change while the screen is hidden cannot arm it, whichever stream delivers first. The arming
    /// belongs to the cover, which cancels it on any dismissal or replacement.
    ///
    /// Arming starts when the cover is seen, so that is also when it reads the app to return to,
    /// if it has not yet, and tells VoiceOver what it says.
    private func arm(_ cover: Cover) {
        switch (inSight(cover), cover.arming) {
        case (true, nil):
            if case .unread = cover.returnTo { cover.returnTo = .read(focus.frontmost()) }
            announce(cover, .interrupting)
            cover.shown.cameIntoSight()
            log.info("cover seen, announced to VoiceOver")
            cover.arming = Task { [timekeeper, log] in
                try await timekeeper.sleep(for: Self.unarmedFor)
                try Task.checkCancellation()
                cover.accepting = true
                log.info("cover armed")
            }
        case (true, .some), (false, nil): break
        case (false, .some(let arming)):
            arming.cancel()
            cover.arming = nil
            cover.accepting = false
            let why = cover.panels.isEmpty ? "no display" : hidden.map { $0.map(\.rawValue).sorted().joined(separator: ", ") } ?? "screen not yet known"
            log.info("cover disarmed: \(why, privacy: .public)")
        }
    }

    private func take(down why: String) {
        if let up {
            log.info("cover \(why, privacy: .public): \(up.shown.content.headline.english, privacy: .private)")
            up.close()
            // Focus goes back only while this app holds it: an app the person moved to since keeps it.
            // With no app to return to, this app, whose windows are all closed, steps aside for the one macOS picks.
            if focus.frontmost() == nil {
                if case .read(let app?) = up.returnTo {
                    log.info("cover returns focus to \(app.name, privacy: .public)")
                    focus.activate(app)
                } else {
                    log.info("cover gives up focus: no app to return to")
                    focus.deactivate()
                }
            }
        }
        up = nil
    }
}
