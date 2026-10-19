import SwiftUI

/// A sentence the app says, held as its catalog key and the values it is filled with, so the code and
/// tests that decide what to say read it as English and the screens say it in the app's language.
///
/// [LAW:one-source-of-truth] The key is the English sentence with its holes (`%lld`, `%@`), which is
/// what Localizable.xcstrings is keyed by; a phrase written in source is `"Charging at \(watts) W"`
/// exactly as a `LocalizedStringKey` would be.
struct Phrase: Equatable, Sendable, CustomStringConvertible, ExpressibleByStringInterpolation {
    indirect enum Value: Equatable, Sendable {
        case number(Int)
        case text(String)
        case phrase(Phrase)
    }

    let key: String
    let values: [Value]

    init(key: String, values: [Value]) {
        self.key = key
        self.values = values
    }

    init(stringLiteral literal: String) { self.init(stringInterpolation: StringInterpolation(literal: literal)) }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        values = stringInterpolation.values
    }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key = ""
        fileprivate var values: [Value] = []

        init(literalCapacity: Int, interpolationCount: Int) {}
        fileprivate init(literal: String) { appendLiteral(literal) }

        /// A percent sign in the sentence is `%%` in its key, as it is in a LocalizedStringKey's.
        mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation(_ number: Int) { key += "%lld"; values.append(.number(number)) }
        mutating func appendInterpolation(_ text: String) { key += "%@"; values.append(.text(text)) }
        mutating func appendInterpolation(_ phrase: Phrase) { key += "%@"; values.append(.phrase(phrase)) }
    }

    /// The sentence in `language`: its key looked up in the catalog, then filled with the values.
    func resolve(in language: AppLanguage, bundle: Bundle = .main) -> String {
        fill(language.resolve(key, in: bundle), language: language, bundle: bundle)
    }

    /// The sentence as the code that wrote it reads it: the key filled in.
    var english: String { fill(key, language: .matchSystem, bundle: .main, translating: false) }

    var description: String { english }

    private func fill(_ format: String, language: AppLanguage, bundle: Bundle, translating: Bool = true) -> String {
        let arguments: [CVarArg] = values.map {
            switch $0 {
            case .number(let number): number
            case .text(let text): text
            case .phrase(let phrase): translating ? phrase.resolve(in: language, bundle: bundle) : phrase.english
            }
        }
        return String(format: format, locale: translating ? language.locale : Locale(identifier: "en_US"), arguments: arguments)
    }
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.matchSystem
}

extension EnvironmentValues {
    /// The language the app speaks, for text that is a `Phrase` and not a literal SwiftUI looks up itself.
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

/// A phrase, said in the app's language.
struct PhraseText: View {
    let phrase: Phrase
    @Environment(\.appLanguage) private var language

    init(_ phrase: Phrase) { self.phrase = phrase }

    var body: some View { Text(verbatim: phrase.resolve(in: language)) }
}
