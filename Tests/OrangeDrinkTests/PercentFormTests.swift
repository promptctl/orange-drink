import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the percent sign each language writes: a battery's health, an app's share
// and a chart's tick say it the way a level does, so they can stand beside one in a row.
@MainActor @Suite struct PercentFormTests {
    static let app = Bundle(for: BatteryModel.self)
    /// The number is the Mac region's, as AppLanguage.locale keeps it; the sign is the language's. A no-break space in French and Spanish, so a figure never wraps between its number and its sign.
    static let sign = [("en", "%"), ("fr", "\u{a0}%"), ("es", "\u{a0}%")]

    @Test func healthIsSaidTheWayItsLanguageWritesAPercent() throws {
        let health = try BatteryInformationWords.reference().health.percent
        for (code, sign) in Self.sign {
            #expect(health.resolve(in: AppLanguage(code: code), bundle: Self.app) == "95\(sign)")
        }
    }

    @Test func aShareKeepsItsLocalesNumberAndTakesItsLanguagesSign() {
        for (code, sign) in Self.sign {
            let language = AppLanguage(code: code)
            let decimal = language.locale.decimalSeparator ?? "."
            let shares = [45, 9.1, 0.95].map { ShareFormat.text(percent: $0, locale: language.locale).resolve(in: language, bundle: Self.app) }
            #expect(shares == ["45\(sign)", "9\(decimal)1\(sign)", "0\(decimal)95\(sign)"])
        }
    }

    @Test func aChartTickIsSaidTheWayItsLanguageWritesAPercent() {
        for (code, sign) in Self.sign {
            let language = AppLanguage(code: code)
            let decimal = language.locale.decimalSeparator ?? "."
            #expect([0, 50, 87.5].map { TickFormat.percent($0, locale: language.locale).resolve(in: language, bundle: Self.app) }
                == ["0\(sign)", "50\(sign)", "87\(decimal)5\(sign)"])
        }
    }

    /// One sign for every figure beside a level: a share or a tick is written as a level is.
    @Test func aWholeShareAndAWholeTickAreWrittenAsALevelIs() {
        for (code, _) in Self.sign {
            let language = AppLanguage(code: code)
            let level = BatteryLevel.text(BatteryLevel(percent: 80, approximate: false)).resolve(in: language, bundle: Self.app)
            #expect(ShareFormat.text(percent: 80, locale: language.locale).resolve(in: language, bundle: Self.app) == level)
            #expect(TickFormat.percent(80, locale: language.locale).resolve(in: language, bundle: Self.app) == level)
        }
    }

    /// The unit sits off its number as the percent sign does, so the two axes of one card read alike.
    @Test func anHoursTickIsSaidTheWayItsLanguageWritesAnHour() {
        for (code, sign) in Self.sign {
            let language = AppLanguage(code: code)
            let unit = sign.replacingOccurrences(of: "%", with: "h")
            #expect(TickFormat.hours(2, locale: language.locale).resolve(in: language, bundle: Self.app) == "2\(unit)")
        }
    }
}
