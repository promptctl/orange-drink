import AppKit
import SwiftUI
import os

/// Where a pill sits on a screen, as the alert's position says.
enum PillPlacement {
    /// design-docs/general.md: roughly 280 × 64 pt.
    nonisolated static let size = CGSize(width: 280, height: 64)
    private static let topGap: CGFloat = 12

    /// The pill's size at a multiple of the standard: the window and the drawn pill both read it.
    static func size(scale: Double) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func frame(_ position: Alert.Position, on screen: CGRect, scale: Double) -> CGRect {
        let size = Self.size(scale: scale)
        let x = screen.midX - size.width / 2
        switch position {
        case .center: return CGRect(x: x, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        case .top: return CGRect(x: x, y: screen.maxY - topGap - size.height, width: size.width, height: size.height)
        }
    }
}

/// The two rectangles of a screen a pill and its glow are placed by.
struct ScreenArea: Equatable {
    /// The whole screen, which the glow covers.
    let frame: CGRect
    /// The screen less the menu bar and Dock, which the pill sits in.
    let visibleFrame: CGRect

    /// [LAW:effects-at-boundaries] The screen pills go on now, as AppKit says: none with every display gone.
    @MainActor static func main() -> ScreenArea? {
        (NSScreen.main ?? NSScreen.screens.first).map { ScreenArea(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}

/// The pill's window: it takes the close button's clicks without taking focus.
private final class PillPanel: OverlayPanel {
    let language: AppLanguage

    init(_ content: PillContent, scale: Double, language: AppLanguage, area: ScreenArea, onClose: @escaping () -> Void) {
        self.language = language
        super.init(
            frame: PillPlacement.frame(content.position, on: area.visibleFrame, scale: scale), level: .pill,
            content: PillView(content: content, scale: scale, onClose: onClose).speaking(language))
    }
}

/// Why a pill came down, as its log line says it.
enum PillEnd {
    case closeButton
    case timedOut

    var said: String {
        switch self {
        case .closeButton: "×"
        case .timedOut: "timed out after \(PillController.shownFor)"
        }
    }
}

/// The one pill on screen, with the screen glow its alert asks for: a new alert replaces both, and
/// the close button or `shownFor` of the screen being seen clears both.
///
/// [LAW:single-enforcer] `up` is the only record of whether a pill is up; its windows and its
/// countdown live and die together. What moves them is two separate inputs: `hidden` decides
/// whether the countdown runs, and a change of displays decides where the windows are.
@MainActor final class PillController {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "alerts")
    /// How long a pill stays up while the screen can be seen, unless its × or a newer alert takes it
    /// down first. Each return to being seen starts it again, in full.
    nonisolated static let shownFor: Duration = .seconds(8)

    @MainActor private struct Up {
        let content: PillContent
        /// The bubble size the pill was built at, which a move to another screen keeps.
        let scale: Double
        let panel: PillPanel
        /// nil when the alert has Border Glow off.
        let glow: GlowPanel?
        /// nil while the screen is hidden.
        var countdown: Task<Void, any Error>?

        func close() { countdown?.cancel(); panel.close(); glow?.close() }

        func place(on area: ScreenArea) {
            panel.setFrame(PillPlacement.frame(content.position, on: area.visibleFrame, scale: scale), display: true)
            glow?.setFrame(area.frame, display: true)
        }
    }

    private let appearance: NotificationAppearanceModel
    private let language: AppLanguageModel
    private let timekeeper: any Timekeeper
    private let currentScreen: @MainActor () -> ScreenArea?
    private let orderFront: @MainActor (OverlayPanel) -> Void
    private var up: Up?
    /// A launched app has someone in front of it, so nothing hides the screen until the system says so.
    private var hidden: Set<ScreenHider> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    nonisolated(unsafe) private var following: [Task<Void, Never>] = []

    /// [LAW:effects-at-boundaries] `orderFront` is what puts a built window on the screen, and it has no default: the app
    /// orders each panel front, and a test holds them, so `make test` builds and asserts on the panels without showing them.
    init(appearance: NotificationAppearanceModel, language: AppLanguageModel, orderFront: @escaping @MainActor (OverlayPanel) -> Void,
         timekeeper: any Timekeeper = SystemTimekeeper(), screen: @escaping @MainActor () -> ScreenArea? = ScreenArea.main) {
        self.appearance = appearance
        self.language = language
        self.orderFront = orderFront
        self.timekeeper = timekeeper
        currentScreen = screen
    }

    deinit { following.forEach { $0.cancel() } }

    var shown: PillContent? { up?.content }
    /// The panel's frame in screen coordinates while a pill is up.
    var shownFrame: CGRect? { up?.panel.frame }
    /// The glow's frame in screen coordinates while the shown pill's alert has Border Glow on.
    var shownGlowFrame: CGRect? { up?.glow?.frame }
    /// The shown pill's panel, then its glow's while Border Glow is on: the windows macOS stacks over other apps.
    var shownPanels: [OverlayPanel] { up.map { [$0.panel] + ($0.glow.map { [$0] } ?? []) } ?? [] }
    /// The language the shown pill was handed: the app's at the moment it came up.
    var shownLanguage: AppLanguage? { up?.panel.language }
    /// The strength the shown glow was built at.
    var shownGlowStrength: NotificationAppearance.GlowStrength? { up?.glow?.strength }
    /// Whether the shown pill's `shownFor` is running: not while the screen is hidden.
    var shownCounting: Bool? { up.map { $0.countdown != nil } }

    /// The sink an `AlertCenter` delivers to. The temperature warning has no pill so far.
    func deliver(_ firing: Firing, reading: BatteryReading) {
        switch firing {
        case .threshold(let alert): show(PillContent(alert, reading: reading))
        case .pluggedIn: show(.power("Plugged In", severity: .green, reading: reading))
        case .unplugged: show(.power("On Battery", severity: .orange, reading: reading))
        case .temperatureWarning: break
        }
    }

    /// The sink an `AlertCenter` delivers a watched device's firing to.
    func deliver(_ firing: DeviceFiring) { show(PillContent(firing)) }

    func show(_ content: PillContent) {
        // [LAW:no-silent-failure] A Mac with every display gone is a state to live through, but the lost
        // alert is logged. A pill already up stays, with the countdown `hidden` gave it.
        guard let area = currentScreen() else {
            Self.log.error("no screen to show the pill on: \(content.headline.english, privacy: .private)")
            return
        }
        dismiss("replaced")
        let look = appearance.value
        let panel = PillPanel(content, scale: look.bubbleSize.scale, language: language.value, area: area, onClose: { [weak self] in self?.close(.closeButton) })
        // [LAW:dataflow-not-control-flow] The glow is built from the content's flag, so a pill whose
        // alert has Border Glow off is a pill with no glow, whatever the pill before it had.
        let glow = content.glow ? GlowPanel(severity: content.severity, strength: look.glowStrength, frame: area.frame) : nil
        let pill = Up(content: content, scale: look.bubbleSize.scale, panel: panel, glow: glow, countdown: countdown())
        up = pill
        // Their levels stack the glow under the pill, whichever is ordered front first.
        shownPanels.forEach(orderFront)
        let counting = pill.countdown == nil ? ", held" : " for \(Self.shownFor)"
        Self.log.info("pill shown at \(content.position.rawValue, privacy: .public)\(counting, privacy: .public): \(content.headline.english, privacy: .private)")
    }

    /// What hides the screen now. Every change gives the pill up a new countdown from `countdown()`;
    /// the same set again, as the first one the system sends at launch may be, is no change.
    func screen(hidden: Set<ScreenHider>) {
        guard hidden != self.hidden else { return }
        self.hidden = hidden
        let said = hidden.isEmpty ? "seen" : "hidden by \(hidden.map(\.rawValue).sorted().joined(separator: ", "))"
        Self.log.info("screen \(said, privacy: .public)")
        guard var pill = up else { return }
        pill.countdown?.cancel()
        pill.countdown = countdown()
        up = pill
        let counting = pill.countdown == nil ? "held" : "counting \(Self.shownFor) again"
        Self.log.info("pill \(counting, privacy: .public): \(pill.content.headline.english, privacy: .private)")
    }

    /// The displays changed: the pill up moves onto the current main screen, keeping its countdown.
    func screensChanged() {
        guard let pill = up else { return }
        // [LAW:no-silent-failure] With no screen the pill stays where it was, and the next change places it.
        guard let area = currentScreen() else {
            Self.log.error("no screen to place the pill on: \(pill.content.headline.english, privacy: .private)")
            return
        }
        pill.place(on: area)
        Self.log.info("pill placed in \(String(describing: area.visibleFrame), privacy: .public): \(pill.content.headline.english, privacy: .private)")
    }

    /// Feeds the controller what hides the screen and when the displays change, for as long as it lives.
    func follow(screen hiders: AsyncStream<Set<ScreenHider>>, layout: AsyncStream<Void>) {
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

    /// [LAW:single-enforcer] The one place a countdown is made, from `hidden` alone: none while the
    /// screen is hidden, a full `shownFor` while it is seen.
    ///
    /// [LAW:no-ambient-temporal-coupling] The countdown belongs to the pill's `Up`, which cancels it
    /// on any close, replacement, or change of `hidden`. One of those can land between the wake and
    /// this task's turn on the main actor; it has cancelled the task by then, so the check after the
    /// sleep is that state. It holds `self` strongly, at most for `shownFor`, so a counting pill comes
    /// down even if its controller is dropped.
    private func countdown() -> Task<Void, any Error>? {
        hidden.isEmpty ? Task { [timekeeper] in
            try await timekeeper.sleep(for: Self.shownFor)
            try Task.checkCancellation()
            self.close(.timedOut)
        } : nil
    }

    /// Takes down the pill showing, if any, without telling waiters: a replacement may follow.
    private func dismiss(_ why: String) {
        if let up {
            // A device pill's headline holds the device's name, which AlertCenter logs as private too.
            Self.log.info("pill \(why, privacy: .public): \(up.content.headline.english, privacy: .private)")
            up.close()
        }
        up = nil
    }

    func close(_ end: PillEnd) {
        dismiss("closed: \(end.said)")
        let released = waiters
        waiters = []
        for waiter in released { waiter.resume() }
    }

    /// Returns once no pill is up.
    func untilClosed() async {
        guard shown != nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
