import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The Done when of orange-device-sources-rec.66c, part three: the widget file the current release wrote
// decodes to the same list and this release writes the same bytes, and a pair of a source and a reason that means nothing is not
// a value a file can hold.
struct UnreadSourceWireTests {
    /// The six pairs the current release writes, as it writes them: the object's keys sorted, each reason its source's own.
    private static let shipped: [(json: String, source: UnreadSource)] = [
        (#"{"reason":"waiting","source":"bluetooth"}"#, .bluetooth(.waiting)),
        (#"{"reason":"unanswered","source":"bluetooth"}"#, .bluetooth(.unanswered)),
        (#"{"reason":"denied","source":"bluetooth"}"#, .bluetooth(.denied)),
        (#"{"reason":"ended","source":"bluetooth"}"#, .bluetooth(.ended)),
        (#"{"reason":"waiting","source":"iphone"}"#, .iPhone(.waiting)),
        (#"{"reason":"ended","source":"iphone"}"#, .iPhone(.ended)),
    ]

    /// What this release adds: an iPhone reachable and not listed, three kinds. An older reader of a new file fails it loudly
    /// (`aPairThatMeansNothingFailsTheFile`), as any shelf it cannot read.
    private static let added: [(json: String, source: UnreadSource)] = [
        (#"{"reason":"locked","source":"iphone"}"#, .iPhoneMissing(.locked)),
        (#"{"reason":"notTrusted","source":"iphone"}"#, .iPhoneMissing(.notTrusted)),
        (#"{"reason":"unreadable","source":"iphone"}"#, .iPhoneMissing(.unreadable)),
    ]

    @Test(arguments: added) func eachAddedPairIsWrittenAndReadAsItsBytes(json: String, source: UnreadSource) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try String(decoding: encoder.encode(source), as: UTF8.self) == json)
        #expect(try JSONDecoder().decode(UnreadSource.self, from: Data(json.utf8)) == source)
    }

    @Test func aWidgetFileTheCurrentReleaseWroteDecodesToTheSameList() throws {
        let file = #"{"ranked":[],"pinned":{"ids":[]},"unlevelled":[],"unreadSources":[\#(Self.shipped.map(\.json).joined(separator: ","))]}"#
        let list = try JSONDecoder().decode(WidgetDeviceList.self, from: Data(file.utf8))
        #expect(list == WidgetDeviceList(ranked: [], pinned: [], unlevelled: [], unreadSources: Self.shipped.map(\.source)))
    }

    @Test(arguments: shipped) func eachPairIsWrittenAsTheCurrentReleaseWritesIt(json: String, source: UnreadSource) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try String(decoding: encoder.encode(source), as: UTF8.self) == json)
    }

    @Test(arguments: UnreadSource.all) func everyReasonSurvivesTheFile(source: UnreadSource) throws {
        #expect(try JSONDecoder().decode(UnreadSource.self, from: JSONEncoder().encode(source)) == source)
    }

    /// A reason is its source's own: a source's file holding another's, or one nobody has, is no value.
    @Test(arguments: [("iphone", "unanswered"), ("iphone", "denied"), ("iphone", "nonsense"), ("bluetooth", "nonsense")])
    func aPairThatMeansNothingFailsTheFile(source: String, reason: String) {
        let object = #"{"reason":"\#(reason)","source":"\#(source)"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(UnreadSource.self, from: Data(object.utf8)) }
    }

    /// The reader tries a source's list that did not arrive first, so one string for both sides of a source would read as the
    /// first. Every case a side gains is held to it.
    @Test func aSourcesTwoSidesNeverShareAReasonString() {
        #expect(Set(IPhoneNoList.allCases.map(\.rawValue)).isDisjoint(with: IPhoneMissing.allCases.map(\.rawValue)))
    }
}
