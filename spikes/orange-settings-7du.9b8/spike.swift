// Spike orange-settings-7du.9b8: can the app language change take effect without a restart?
// Build and run: ./run.sh   (headless: no window is ordered front, no screenshot is taken)
//
// Three surfaces, read back as text, before and after each switch:
//   window / panel  SwiftUI hosting views (the settings window and the MenuBarExtra panel are both SwiftUI)
//   status item     an NSStatusItem whose title the app sets from code
import AppKit
import SwiftUI
import Vision

@MainActor @Observable final class Choice {
    /// nil is "Match System".
    var language: String?
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
            content.environment(\.locale, choice.language.map(Locale.init(identifier:)) ?? .init(identifier: Bundle.main.preferredLocalizations[0]))
        }
    }
}

/// What a SwiftUI surface draws, read back: rendered offscreen (not a screen capture) and recognised as text.
@MainActor func drawn(_ renderer: ImageRenderer<some View>) -> [String] {
    guard let image = renderer.cgImage else { return ["<no image>"] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try! VNImageRequestHandler(cgImage: image).perform([request])
    return request.results!.compactMap { $0.topCandidates(1).first?.string }
}

/// The explicit-lookup method for strings no SwiftUI view draws: find the .lproj for the chosen language.
func localized(_ key: String, language: String?) -> String {
    let code = language ?? Bundle.main.preferredLocalizations[0]
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else {
        fatalError("no \(code).lproj in the app bundle")
    }
    return bundle.localizedString(forKey: key, value: nil, table: nil)
}

@MainActor func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

@MainActor func run() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let choice = Choice()
    func render(_ v: Surface.Variant) -> ImageRenderer<some View> {
        let r = ImageRenderer(content: Surface(choice: choice, variant: v).padding(8).frame(width: 360).background(.white).foregroundStyle(.black))
        r.scale = 3
        return r
    }
    let plain = render(.noEnvironment), withLocale = render(.localeEnvironment)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }

    print("process: Bundle.main.preferredLocalizations = \(Bundle.main.preferredLocalizations)  Locale.preferredLanguages = \(Locale.preferredLanguages)")
    func show(_ step: String) {
        // The status item is made the way the app makes it: once, then re-set when the choice changes.
        let staleTitle = NSLocalizedString("Battery", comment: "")      // Foundation's cached lookup
        spin()
        print("\n== \(step)   (choice = \(choice.language ?? "Match System"))")
        print("  SwiftUI, no locale environment : \(drawn(plain))")
        print("  SwiftUI, .environment(\\.locale): \(drawn(withLocale))")
        print("  status item, NSLocalizedString : \(staleTitle)")
        item.button?.title = localized("Battery", language: choice.language)
        print("  status item, lproj lookup      : \(item.button?.title ?? "<no button>")")
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
