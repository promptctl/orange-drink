import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The Done when of orange-device-sources-rec.66c, part one: what each reason of each source says and
// shows is the words and glyph it had before the reasons became each source's own, written out here so a refactor of the type
// cannot move one.
struct UnreadReasonWordsTests {
    private struct Words: Sendable {
        let source: UnreadSource
        let widget: String
        let panel: String
        let glyph: String
    }

    private static let devices = DeviceKind.accessory.symbol
    private static let warns = MacBattery.stoppedGlyph

    private static let all: [Words] = [
        Words(source: .bluetooth(.waiting), widget: "Reading devices…", panel: "Reading your Bluetooth devices…", glyph: devices),
        Words(source: .bluetooth(.unanswered), widget: "Answer the Bluetooth prompt", panel: "Answer the Bluetooth prompt to see your devices.", glyph: devices),
        Words(source: .bluetooth(.denied), widget: "Bluetooth is not allowed",
              panel: "This app isn't allowed to use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth, then quit and reopen the app.",
              glyph: warns),
        Words(source: .bluetooth(.ended), widget: "Bluetooth unavailable", panel: "Bluetooth readings stopped. Quit and reopen the app.", glyph: warns),
        Words(source: .iPhone(.waiting), widget: "Reading iPhones…", panel: "Reading your iPhones and iPads…", glyph: devices),
        Words(source: .iPhone(.ended), widget: "iPhones unavailable", panel: "iPhone readings stopped. Quit and reopen the app.", glyph: warns),
        // A reachable iPhone that could not be identified (orange-device-sources-rec.70o).
        Words(source: .iPhoneMissing(.locked), widget: "An iPhone is locked",
              panel: "An iPhone or iPad is connected but locked, so it can't be listed. Unlock it to see it here.", glyph: warns),
        Words(source: .iPhoneMissing(.notTrusted), widget: "Trust this Mac on an iPhone",
              panel: "An iPhone or iPad is connected but doesn't trust this Mac. Unlock it and tap Trust to see it here.", glyph: warns),
        Words(source: .iPhoneMissing(.unreadable), widget: "An iPhone could not be read",
              panel: "An iPhone or iPad is connected but couldn't be read.", glyph: warns),
    ]

    @Test(arguments: all) private func eachReasonSaysWhatItAlwaysSaid(words: Words) {
        #expect(words.source.text.english == words.widget)
        #expect(words.source.explanation.english == words.panel)
        #expect(words.source.glyph == words.glyph)
    }
}
