import Foundation

extension AppLanguage: Stored {
    static let storageKey = "app.language"
}

extension AppLanguage {
    /// Match System, then the bundle's development language, then the rest by code.
    static func choices(in bundle: Bundle = .main) -> [AppLanguage] {
        let carried = bundle.localizations.filter { $0 != "Base" }
        let development = bundle.developmentLocalization
        let ordered = carried.filter { $0 == development } + carried.filter { $0 != development }.sorted()
        return [matchSystem] + ordered.map { AppLanguage(code: $0) }
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
