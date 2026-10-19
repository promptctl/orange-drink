// Spike orange-settings-7du.9b8: can the app language change take effect without a restart?
// Build and run: ./run.sh   (no window is ordered front, no screenshot is taken)
//
// Surfaces, read back as text, before and after each switch in one running process:
//   hosted SwiftUI  a live NSHostingView in a window never shown (the settings window and the MenuBarExtra
//                   panel are both SwiftUI hosting views), drawn offscreen and read back by OCR
//   status item     an NSStatusItem whose title the app sets from code
// With no arguments the process runs in the real Mac's language. `-AppleLanguages "(fr)"` forces the
// Mac's language at launch; it sits in the argument domain, which no runtime write can outrank.
import AppKit
import SwiftUI
import Vision

@MainActor @Observable final class Choice {
    /// nil is "Match System".
    var language: String?

    /// The current locale with only its language swapped, so the region's dates and numbers stay.
    var locale: Locale {
        guard let language else { return .autoupdatingCurrent }
        var parts = Locale.Components(locale: .current)
        parts.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: parts)
    }
}

/// What the SwiftUI surfaces resolve against. `Text("key")` looks the key up in Bundle.main.
struct Surface: View {
    let choice: Choice
    let variant: Variant
    enum Variant { case noEnvironment, localeEnvironment }

    var body: some View {
        let content = VStack {
            Text("Language")
            Text("Choose the language the app uses")
        }
        switch variant {
        case .noEnvironment: content
        case .localeEnvironment:
            // Match System: the Mac's own preferred language, not a stored one.
            content.environment(\.locale, choice.locale)
        }
    }
}

/// What a live hosting view draws, read back: drawn offscreen (not a screen capture) and recognised as text.
@MainActor func drawn(_ host: NSView) -> [String] {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ["<no bitmap>"] }
    host.cacheDisplay(in: host.bounds, to: rep)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try! VNImageRequestHandler(cgImage: rep.cgImage!).perform([request])
    return request.results!.compactMap { $0.topCandidates(1).first?.string }
}

/// The explicit-lookup method for strings no SwiftUI view draws: the .lproj that best matches the choice
/// (so "pt-BR" finds "pt"), the development language when nothing matches.
func localized(_ key: String, language: String?) -> String {
    let wanted = language.map { [$0] } ?? Bundle.main.preferredLocalizations
    let code = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: wanted).first ?? "en"
    let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
    return bundle.localizedString(forKey: key, value: nil, table: nil)
}

@MainActor func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

@MainActor func run() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let choice = Choice()
    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    defer { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }   // the spike leaves no stored language behind

    func host(_ v: Surface.Variant) -> NSHostingView<some View> {
        let h = NSHostingView(rootView: Surface(choice: choice, variant: v).padding(8).frame(width: 360).background(.white).foregroundStyle(.black))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = h   // never ordered front
        objc_setAssociatedObject(h, "w", w, .OBJC_ASSOCIATION_RETAIN)
        return h
    }
    let plain = host(.noEnvironment), withLocale = host(.localeEnvironment)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    // A status item made the usual way: its title is set once, at launch, and never again.
    let setOnce = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(setOnce) }
    setOnce.button?.title = NSLocalizedString("Battery", comment: "")

    print("process: Bundle.main.preferredLocalizations = \(Bundle.main.preferredLocalizations)  Locale.preferredLanguages = \(Locale.preferredLanguages)")
    func show(_ step: String) {
        spin()
        print("\n== \(step)   (choice = \(choice.language ?? "Match System"))")
        print("  hosted SwiftUI, no locale environment  : \(drawn(plain))")
        print("  hosted SwiftUI, .environment(\\.locale) : \(drawn(withLocale))")
        print("  status item, set once at launch        : \(setOnce.button!.title)")
        print("  fresh NSLocalizedString call           : \(NSLocalizedString("Battery", comment: ""))")
        item.button?.title = localized("Battery", language: choice.language)
        print("  status item, re-set from .lproj lookup : \(item.button!.title)")
    }
    show("launch")
    choice.language = "fr"; UserDefaults.standard.set(["fr"], forKey: "AppleLanguages")
    show("switch to fr, same process")
    choice.language = "en"; UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    show("switch to en, same process")
    choice.language = nil; UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    show("Match System")
}

@main struct Spike { @MainActor static func main() { run() } }
