import Foundation

/// design-docs/charging.md's Charge Limit: whether charging pauses at a target, and the target.
///
/// The target is kept while the limit is off, so turning it back on shows the level last chosen.
struct ChargeLimit: Stored {
    static let storageKey = "charging.limit"

    var isOn = false
    var target = ChargeTarget.standard
}

typealias ChargeLimitModel = StoredModel<ChargeLimit>

/// A level the limit can hold the battery at: one of the levels the Charging screen offers.
///
/// [LAW:types-are-the-program] The memberwise init is private, so a target is one of `all` or one decoded
/// from a stored level that is in `all`. 100% is not offered: charging to full is the limit turned off.
struct ChargeTarget: Codable, Hashable, Sendable {
    let percent: Int

    private init(percent: Int) { self.percent = percent }

    /// From half to 95%, in fives.
    static let all = stride(from: 50, through: 95, by: 5).map(ChargeTarget.init(percent:))
    static let standard = ChargeTarget(percent: 80)

    /// [LAW:parse-dont-validate] A stored level the screen does not offer throws, rather than being clamped.
    init(from decoder: any Decoder) throws {
        let percent = try decoder.singleValueContainer().decode(Int.self)
        guard Self.all.contains(where: { $0.percent == percent }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(percent)% is not an offered charge target"))
        }
        self.percent = percent
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(percent)
    }
}
