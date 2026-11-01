import SwiftUI

/// The language text is said in: Match System (no code) or one of the languages the String Catalog carries. The
/// app's user chooses it on the General screen; a placed widget always matches the Mac's.
///
/// Spike orange-settings-7du.9b8: SwiftUI text follows `.environment(\.locale, …)` in the running
/// process, and nothing else does, so `locale` is what the window and the panel are handed and
/// `resolve` is the lookup for any string no SwiftUI view draws.
struct AppLanguage: Codable, Hashable, Sendable {
    /// nil is Match System: the Mac's language, as it was when the app launched.
    var code: String?

    init() { code = nil }
    init(code: String?) { self.code = code }

    static let matchSystem = AppLanguage()

    /// The current locale with only its language swapped, so the Mac's region keeps its dates and numbers.
    var locale: Locale {
        guard let code else { return .autoupdatingCurrent }
        var parts = Locale.Components(locale: .current)
        let chosen = Locale.Language(identifier: code)
        parts.languageComponents.languageCode = chosen.languageCode
        parts.languageComponents.script = chosen.script   // the Mac's script belongs to the Mac's language, not this one
        return Locale(components: parts)
    }

    /// `key` in this language: the .lproj that best matches the choice, the development language when none does.
    func resolve(_ key: String, in bundle: Bundle = .main) -> String {
        let wanted = code.map { [$0] } ?? bundle.preferredLocalizations
        let match = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: wanted).first ?? bundle.developmentLocalization
        let lproj = bundle.path(forResource: match, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        return lproj.localizedString(forKey: key, value: nil, table: nil)
    }
}
