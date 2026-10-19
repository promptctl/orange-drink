import SwiftUI

/// The language the app speaks, chosen on the General screen: Match System (no code) or one of the
/// languages the String Catalog carries.
///
/// Spike orange-settings-7du.9b8: SwiftUI text follows `.environment(\.locale, …)` in the running
/// process, and nothing else does, so `locale` is what the window and the panel are handed and
/// `resolve` is the lookup for any string no SwiftUI view draws.
struct AppLanguage: Stored, Hashable {
    static let storageKey = "app.language"

    /// nil is Match System: the Mac's language, as it was when the app launched.
    var code: String?

    init() { code = nil }
    init(code: String?) { self.code = code }

    static let matchSystem = AppLanguage()

    /// Match System, then the bundle's development language, then the rest by code.
    static func choices(in bundle: Bundle = .main) -> [AppLanguage] {
        let carried = bundle.localizations.filter { $0 != "Base" }
        let development = bundle.developmentLocalization
        let ordered = carried.filter { $0 == development } + carried.filter { $0 != development }.sorted()
        return [matchSystem] + ordered.map { AppLanguage(code: $0) }
    }

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

    /// What the pop-up lists: a language in its own name, Match System in the language being spoken now.
    func menuTitle(speaking current: AppLanguage, in bundle: Bundle = .main) -> String {
        guard let code else { return current.resolve("Match System", in: bundle) }
        let own = Locale(identifier: code)
        guard let name = own.localizedString(forIdentifier: code) else { return code }
        return name.prefix(1).uppercased(with: own) + name.dropFirst()
    }
}

typealias AppLanguageModel = StoredModel<AppLanguage>
