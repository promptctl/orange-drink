import AppKit
import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
import os
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which batteries the widget lists, what it draws for them in each
// style at each size, and which widgets redraw when the app changes a file, from a shelf in a directory of the test's own.
let allBatteriesSizes = widgetSizes + [(.systemExtraLarge, CGSize(width: 715, height: 354))]

/// The content area of each size: WidgetKit keeps its margin inside a widget.
let allBatteriesContents = allBatteriesSizes.map { family, size in
    (family, CGSize(width: size.width - 2 * AllBatteriesWidgetTests.margin, height: size.height - 2 * AllBatteriesWidgetTests.margin))
}

@MainActor @Suite(.timeLimit(.minutes(1))) final class AllBatteriesWidgetTests {
    /// WidgetKit keeps this margin inside a widget: a rendering is the content area.
    nonisolated static let margin: CGFloat = 16

    static let charging = MacBattery.level(percent: 80, charging: true)
    static let onBattery = MacBattery.level(percent: 79, charging: false)

    static func device(_ address: String, _ percent: Int, kind: DeviceKind = .accessory, approximate: Bool = false) -> WidgetDevice {
        WidgetDevice(address: address, name: "Device \(address)", kind: kind, level: BatteryLevel(percent: percent, approximate: approximate))
    }

    static let twentyLevels = Array(stride(from: 21, through: 97, by: 4))
    static let twenty = twentyLevels.map { device("\($0)", $0) }

    /// The reference's other three rings: phone, wireless arcs, tablet.
    static let three = [device("AA", 95, kind: .phone), device("BB", 54), device("CC", 40, kind: .tablet)]

    static func entry(_ mac: MacBattery, _ devices: [WidgetDevice], style: WidgetStyle = .rings) -> AllBatteriesEntry {
        AllBatteriesEntry(date: .now, mac: .success(.running(mac)), devices: .success(.running(.connected(devices))), style: style)
    }

    static func view(_ entry: AllBatteriesEntry, _ family: WidgetFamily = .systemSmall) -> AllBatteriesView {
        AllBatteriesView(entry: entry, appName: "Orange Drink", family: family)
    }

    /// What the widget says, in reading order.
    static func texts(_ entry: AllBatteriesEntry, _ family: WidgetFamily = .systemSmall) throws -> [String] {
        try view(entry, family).inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: the list

    @Test func theMacComesFirstThenTheDevicesInThePanelsRanking() {
        #expect(AllBatteries(mac: Self.charging, devices: .connected(Self.three)) == .listed([
            WidgetBattery(glyph: "laptopcomputer", level: BatteryLevel(percent: 80, approximate: false), charging: true),
            WidgetBattery(glyph: "iphone", level: BatteryLevel(percent: 95, approximate: false), charging: false),
            WidgetBattery(glyph: "dot.radiowaves.left.and.right", level: BatteryLevel(percent: 54, approximate: false), charging: false),
            WidgetBattery(glyph: "ipad", level: BatteryLevel(percent: 40, approximate: false), charging: false),
        ]))
    }

    @Test func aMacWithNoBatteryIsNotListedAndOneWithNoReadingIsListedEmpty() {
        let devices = [Self.device("AA", 95, approximate: true)]
        #expect(AllBatteries(mac: .noBattery, devices: .connected(devices)) == .listed([WidgetBattery(devices[0])]))
        let waiting = WidgetBattery(glyph: "laptopcomputer", level: nil, charging: false)
        #expect(AllBatteries(mac: .waiting, devices: .connected(devices)) == .listed([waiting, WidgetBattery(devices[0])]))
        let stopped = WidgetBattery(glyph: "exclamationmark.triangle", level: nil, charging: false)
        #expect(AllBatteries(mac: .ended, devices: .connected(devices)) == .listed([stopped, WidgetBattery(devices[0])]))
        #expect(AllBatteries(mac: .ended, devices: .connected([])) == .listed([stopped]))
        #expect(WidgetBattery(devices[0]).level == BatteryLevel(percent: 95, approximate: true))
    }

    // MARK: the sizes

    @Test func theWidgetDeclaresSmallMediumLargeAndExtraLarge() {
        #expect(WidgetFamilies.allBatteries == [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }

    @Test func eachSizeHoldsMoreRingsThanTheOneBelowEachShowingItsOwnLevel() throws {
        let entry = Self.entry(Self.charging, Self.twenty)
        let levels = ["80%"] + Self.twentyLevels.map { "\($0)%" }
        let shown = try WidgetFamilies.allBatteries.map { try Self.texts(entry, $0) }
        #expect(shown.map(\.count) == [4, 8, 16, 21])
        for rings in shown { #expect(rings == Array(levels.prefix(rings.count))) }
    }

    @Test func aFullWidgetFillsItsGridARowAtATime() throws {
        let forty = (1...40).map { Self.device("\($0)", $0) }
        let rows = { (family: WidgetFamily, batteries: [WidgetDevice]) in
            BatteryGrid(family, .rings).rows(of: batteries.map(WidgetBattery.init)).map(\.count)
        }
        #expect(WidgetFamilies.allBatteries.map { rows($0, forty) } == [[2, 2], [4, 4], [4, 4, 4, 4], [8, 8, 8, 8]])
        #expect(rows(.systemMedium, Array(forty.prefix(5))) == [4, 1])
        let drawn = try WidgetFamilies.allBatteries.map { try Self.texts(Self.entry(.noBattery, forty), $0).count }
        #expect(drawn == [4, 8, 16, 32])
    }

    // MARK: the drawing

    static func image(_ entry: AllBatteriesEntry, _ family: WidgetFamily, content size: CGSize) throws -> CGImage {
        try widgetImage(view(entry, family), size: size, scheme: .dark, scale: 2)
    }

    /// The four rings of a rendering at Small, in reading order.
    static func cells(_ entry: AllBatteriesEntry) throws -> [RingPixels] {
        let image = try image(entry, .systemSmall, content: content(.systemSmall))
        let cell = image.width / 2
        return try [(0, 0), (1, 0), (0, 1), (1, 1)].map { column, row in
            try RingPixels(#require(image.cropping(to: CGRect(x: column * cell, y: row * cell, width: cell, height: cell))))
        }
    }

    nonisolated static func isGreen(_ colour: NSColor) -> Bool {
        colour.alphaComponent > 0.6 && colour.greenComponent > colour.redComponent + 0.2 && colour.greenComponent > colour.blueComponent + 0.2
    }

    /// The reference's light grey: no hue, bright, and opaque enough not to be the track.
    nonisolated static func isGrey(_ colour: NSColor) -> Bool {
        let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
        return colour.alphaComponent > 0.6 && channels.max()! - channels.min()! < 0.08 && colour.brightnessComponent > 0.6
    }

    /// The share of the circle a charging ring's first steps take up in its bolt's gap.
    static let boltGap = 0.06

    static func expectOtherRingsAreGrey(_ cells: [RingPixels]) {
        for (ring, level) in zip(cells.dropFirst(), [0.95, 0.54, 0.40]) {
            let filled = ring.filledFraction(from: 0, isArc: isGrey)
            #expect(abs(filled - level) < 0.03, "a device's ring filled \(filled), level \(level)")
            #expect(!ring.contains(isGreen))
        }
    }

    @Test func whileChargingTheMacsArcIsGreenWithTheBolt() throws {
        let cells = try Self.cells(Self.entry(Self.charging, Self.three))
        let filled = cells[0].filledFraction(from: Self.boltGap, isArc: Self.isGreen)
        #expect(abs(filled - 0.80) < 0.03, "the Mac's ring filled \(filled)")
        #expect(cells[0].isOpenAtTwelve)
        #expect(cells[0].containsAtTwelve(Self.isGreen))
        Self.expectOtherRingsAreGrey(cells)
    }

    @Test func onBatteryTheMacsArcIsGreyWithNoBolt() throws {
        let cells = try Self.cells(Self.entry(Self.onBattery, Self.three))
        let filled = cells[0].filledFraction(from: 0, isArc: Self.isGrey)
        #expect(abs(filled - 0.79) < 0.03, "the Mac's ring filled \(filled)")
        #expect(!cells[0].isOpenAtTwelve)
        #expect(!cells[0].contains(Self.isGreen))
        Self.expectOtherRingsAreGrey(cells)
    }

    static func ring(_ entry: AllBatteriesEntry, _ family: WidgetFamily, _ size: CGSize) throws -> Double {
        let content = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
        return try RingPixels(image(entry, family, content: content)).across / 2
    }

    @Test func aRingAtSmallIsTheReferencesThirtyEightPointsAcross() throws {
        let across = try Self.ring(Self.entry(Self.onBattery, Self.three), .systemSmall, CGSize(width: 158, height: 158))
        #expect(abs(across - 38) < 4, "a ring is \(across) pt across")
    }

    @Test(arguments: allBatteriesSizes) func aRingIsOneSizeHoweverFewBatteriesThereAre(family: WidgetFamily, size: CGSize) throws {
        let few = try Self.ring(Self.entry(Self.onBattery, Array(Self.three.prefix(1))), family, size)
        let full = try Self.ring(Self.entry(Self.onBattery, Self.twenty), family, size)
        #expect(abs(few - full) < 1, "\(few) pt with two batteries, \(full) pt with a full widget")
    }

    @Test func whatEachStateSays() throws {
        func open(_ mac: Result<Shelved<MacBattery>, any Error>, _ devices: Result<Shelved<WidgetDevices>, any Error>) throws {
            for style in WidgetStyle.allCases {
                #expect(try Self.texts(AllBatteriesEntry(date: .now, mac: mac, devices: devices, style: style)) == ["Open Orange Drink"])
            }
        }
        let running = Result<Shelved<WidgetDevices>, any Error>.success(.running(.connected(Self.three)))
        try open(.success(.appNotRunning), running)
        try open(.failure(ShelfError.noGroupEntitlement), running)
        try open(.success(.running(Self.charging)), .success(.appNotRunning))
        try open(.success(.running(Self.charging)), .failure(ShelfError.noGroupEntitlement))

        for style in WidgetStyle.allCases {
            #expect(try Self.texts(Self.entry(.noBattery, [], style: style)) == ["No batteries"])
        }
        #expect(try Self.texts(Self.entry(.noBattery, Self.three)) == ["95%", "54%", "40%"])
        // A cell has no room for Mac Battery's sentence, and a ring that stopped keeps the rings beside it on
        // the widget. Its warning is the ring's glyph, which the list's test holds.
        #expect(try Self.texts(Self.entry(.ended, Self.three)) == ["–", "95%", "54%", "40%"])
        #expect(try Self.texts(Self.entry(.waiting, Self.three)) == ["–", "95%", "54%", "40%"])
        #expect(try Self.texts(Self.entry(.noBattery, [Self.device("AA", 40, approximate: true)])) == ["~40%"])
    }

    // MARK: the styles

    @Test(arguments: WidgetStyle.allCases, WidgetFamilies.allBatteries) func everyStyleAtEverySizeShowsEachBatterysOwnPercentage(style: WidgetStyle, family: WidgetFamily) throws {
        let shown = try Self.texts(Self.entry(Self.charging, Self.three, style: style), family)
        #expect(shown == ["80%", "95%", "54%", "40%"])
    }

    @Test(arguments: WidgetStyle.allCases) func eachSizeHoldsTheSameBatteriesInEveryStyle(style: WidgetStyle) throws {
        let forty = (1...40).map { Self.device("\($0)", $0) }
        let drawn = try WidgetFamilies.allBatteries.map { try Self.texts(Self.entry(.noBattery, forty, style: style), $0) }
        #expect(drawn.map(\.count) == [4, 8, 16, 32])
        for shown in drawn { #expect(shown == (1...shown.count).map { "\($0)%" }) }
    }

    @Test(arguments: [WidgetStyle.list, .bars]) func rowsTakeTwoRingsWidthAndHalfARingsHeight(style: WidgetStyle) {
        let grids = WidgetFamilies.allBatteries.map { BatteryGrid($0, style) }
        #expect(grids.map(\.columns) == [1, 2, 2, 4])
        #expect(grids.map(\.rows) == [4, 4, 8, 8])
    }

    static func content(_ family: WidgetFamily) throws -> CGSize {
        try #require(allBatteriesContents.first { $0.0 == family }).1
    }

    static func pixels(_ entry: AllBatteriesEntry, _ family: WidgetFamily = .systemSmall) throws -> WidgetPixels {
        try WidgetPixels(image(entry, family, content: content(family)))
    }

    /// The bars of a rendering at Small, in reading order: a full widget's four rows.
    static func bars(_ entry: AllBatteriesEntry) throws -> [WidgetPixels.Run] {
        let whole = try pixels(entry)
        return (0..<4).map { whole.row($0, of: 4).longestRun }
    }

    @Test func eachBarFillsToItsLevelGreenWhileCharging() throws {
        let bars = try Self.bars(Self.entry(Self.charging, Self.three, style: .bars))
        #expect(abs(bars[0].fraction(Self.isGreen) - 0.80) < 0.03, "the Mac's bar filled \(bars[0].fraction(Self.isGreen))")
        for (bar, level) in zip(bars.dropFirst(), [0.95, 0.54, 0.40]) {
            #expect(abs(bar.fraction(Self.isGrey) - level) < 0.03, "a device's bar filled \(bar.fraction(Self.isGrey)), level \(level)")
            #expect(bar.fraction(Self.isGreen) == 0)
        }
    }

    @Test(arguments: [WidgetStyle.list, .bars]) func onlyAChargingBatteryIsGreen(style: WidgetStyle) throws {
        #expect(try Self.pixels(Self.entry(Self.charging, Self.three, style: style)).contains(Self.isGreen))
        #expect(try !Self.pixels(Self.entry(Self.onBattery, Self.three, style: style)).contains(Self.isGreen))
    }

    @Test func theListDrawsNoBar() throws {
        let row = try Self.pixels(Self.entry(Self.charging, Self.three, style: .list)).row(0, of: 4).longestRun
        #expect(row.width < 40, "a run \(row.width) px wide")
    }

    /// Past the row's glyph and percentage a cell is empty, or a percentage would read with the next column's glyph.
    @Test(arguments: WidgetFamilies.allBatteries) func aListRowKeepsItsPercentageBesideItsGlyph(family: WidgetFamily) throws {
        let image = try Self.image(Self.entry(Self.onBattery, [], style: .list), family, content: Self.content(family))
        let row = (4 + 20 + 4 + Int(RowPercentage.width)) * 2
        let rest = try #require(image.cropping(to: CGRect(x: row, y: 0, width: image.width - row, height: image.height)))
        #expect(WidgetPixels(rest).top == nil)
    }

    /// "100%" leaves the percentage column's leading edge clear of digits, so green there is the bolt alone.
    @Test(arguments: [true, false]) func aChargingRowHasItsBoltBesideItsPercentage(charging: Bool) throws {
        let entry = Self.entry(.level(percent: 100, charging: charging), [], style: .bars)
        let image = try Self.image(entry, .systemSmall, content: Self.content(.systemSmall))
        let column = try (Self.content(.systemSmall).width - 4 - RowPercentage.width) * 2
        let strip = try #require(image.cropping(to: CGRect(x: column, y: 0, width: 8 * 2, height: CGFloat(image.height))))
        #expect(WidgetPixels(strip).contains(Self.isGreen) == charging)
    }

    @Test func theLongestPercentageFitsItsColumn() throws {
        let longest = WidgetBattery(glyph: MacBattery.glyph, level: BatteryLevel(percent: 100, approximate: true), charging: false)
        let needed = ImageRenderer(content: BatteryPercentage(battery: longest).font(RowPercentage.font).fixedSize())
        #expect(try #require(needed.nsImage).size.width <= RowPercentage.width)
    }

    /// A row is read in the band the grid gives it, so a bar anywhere else starts somewhere else.
    @Test func barsKeepTheirPlacesHoweverFewBatteriesThereAre() throws {
        let start = { (devices: [WidgetDevice], row: Int) in
            try Self.pixels(Self.entry(.noBattery, devices, style: .bars), .systemMedium).row(row, of: 4).longestRun.start
        }
        let first = try start(Self.twenty, 0)
        #expect(first > 0)
        #expect(try start(Array(Self.twenty.prefix(3)), 1) == first, "a short last row")
        #expect(try start(Array(Self.twenty.prefix(1)), 0) == first, "a lone battery")
    }

    // MARK: the settings

    static func bytes(_ entry: AllBatteriesEntry) throws -> Data {
        try #require(image(entry, .systemSmall, content: content(.systemSmall)).dataProvider?.data as Data?)
    }

    /// A shelf of the test's own, holding the charging Mac and the three devices.
    static func filledShelf() throws -> URL {
        let shelf = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { _ in }.publish(charging)
        ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { _ in }.publish(.connected(three))
        return shelf
    }

    static func configured(_ style: WidgetStyle, in shelf: URL, log: Logger = ShelfLog.log) -> AllBatteriesEntry {
        let configuration = AllBatteriesIntent()
        configuration.style = style
        return AllBatteriesEntry(date: .now, directory: .success(shelf), log: log, configuration: configuration)
    }

    @Test(arguments: WidgetStyle.allCases) func aWidgetsStyleSettingGivesAnEntryDrawnInThatStyle(style: WidgetStyle) throws {
        let shelf = try Self.filledShelf()
        defer { try? FileManager.default.removeItem(at: shelf) }
        let drawn = try Self.bytes(Self.configured(style, in: shelf))
        #expect(try drawn == Self.bytes(Self.entry(Self.charging, Self.three, style: style)))
        for other in WidgetStyle.allCases where other != style {
            #expect(try drawn != Self.bytes(Self.entry(Self.charging, Self.three, style: other)))
        }
    }

    @Test(arguments: [WidgetStyle.list, .bars]) func eachTimelineLogsItsStyle(style: WidgetStyle) async throws {
        // A category of the test's own, because the host app publishes into the shelf's.
        let category = "style-\(UUID().uuidString)"
        let log = try BatteryLog(category: category)
        let shelf = try Self.filledShelf()
        defer { try? FileManager.default.removeItem(at: shelf) }
        _ = Self.configured(style, in: shelf, log: Logger(subsystem: IOKitBattery.logSubsystem, category: category))
        let line = "widget style \(style.rawValue)"
        #expect(try await log.logged(line))
        #expect(try log.messages().contains(line), "the line is public, and a shelf's path holds the account's name")
    }

    @Test func aWidgetWithNoSavedStyleDrawsRingsAndASavedStyleKeepsItsName() {
        #expect(AllBatteriesIntent().style == .rings)
        #expect(WidgetStyle.allCases.map(\.rawValue) == ["rings", "list", "bars"])
    }

    // MARK: the shelf

    @Test func aPlacedWidgetKeepsTheKindItWasSavedUnder() {
        #expect(WidgetKind.macBattery.rawValue == "MacBattery")
        #expect(WidgetKind.deviceBattery.rawValue == "DeviceBattery")
        #expect(WidgetKind.allBatteries.rawValue == "AllBatteries")
    }

    @Test func eachFileRedrawsTheWidgetsThatDrawItAndTheWidgetReadsBothFiles() throws {
        let shelf = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shelf) }
        var asked: [WidgetKind] = []
        let mac = ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { asked.append($0) }
        let devices = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { asked.append($0) }
        func reloads(_ change: () -> Void) -> [WidgetKind] {
            asked = []
            change()
            return asked
        }

        #expect(reloads { mac.publish(Self.charging) } == [.macBattery, .allBatteries])
        #expect(reloads { devices.publish(.connected(Self.three)) } == [.deviceBattery, .allBatteries])
        #expect(reloads { mac.publish(Self.charging) } == [])
        #expect(reloads { devices.publish(.connected(Self.three)) } == [])

        func shelved() -> AllBatteriesEntry { AllBatteriesEntry(date: .now, directory: .success(shelf), log: ShelfLog.log, configuration: AllBatteriesIntent()) }
        #expect(try Self.texts(shelved()) == ["80%", "95%", "54%", "40%"])

        #expect(reloads { mac.publish(Self.onBattery) } == [.macBattery, .allBatteries])
        #expect(reloads { mac.publishQuit() } == [.macBattery, .allBatteries])
        #expect(reloads { devices.publishQuit() } == [.deviceBattery, .allBatteries])
        #expect(try Self.texts(shelved()) == ["Open Orange Drink"])
    }
}

/// A rendering read back along its lines of pixels: rows of a widget, and the bars in them.
struct WidgetPixels {
    /// A horizontal stretch of painted pixels.
    struct Run {
        let start: Int
        let colours: [NSColor]

        var width: Int { colours.count }

        /// The share of the run a colour takes up.
        func fraction(_ matches: (NSColor) -> Bool) -> Double {
            Double(colours.filter(matches).count) / Double(width)
        }
    }

    private let rep: NSBitmapImageRep

    init(_ image: CGImage) { rep = NSBitmapImageRep(cgImage: image) }

    private func colour(_ x: Int, _ y: Int) -> NSColor? { rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }

    /// One band of a rendering cut into equal rows from the top, as a grid cuts a widget.
    func row(_ index: Int, of rows: Int) -> WidgetPixels {
        let height = rep.pixelsHigh / rows
        return WidgetPixels(rep.cgImage!.cropping(to: CGRect(x: 0, y: index * height, width: rep.pixelsWide, height: height))!)
    }

    /// The longest unbroken run on any line: in a row with a bar, the bar's track.
    var longestRun: Run {
        (0..<rep.pixelsHigh).map(run(onLine:)).max { $0.width < $1.width } ?? Run(start: 0, colours: [])
    }

    private func run(onLine y: Int) -> Run {
        var longest = Run(start: 0, colours: [])
        var current: [NSColor] = []
        for x in 0...rep.pixelsWide {
            if x < rep.pixelsWide, let colour = colour(x, y), Self.isPainted(colour) {
                current.append(colour)
            } else {
                if current.count > longest.width { longest = Run(start: x - current.count, colours: current) }
                current = []
            }
        }
        return longest
    }

    private static func isPainted(_ colour: NSColor) -> Bool { colour.alphaComponent > 0.05 }

    private func line(_ y: Int, contains matches: (NSColor) -> Bool) -> Bool {
        (0..<rep.pixelsWide).contains { x in colour(x, y).map(matches) ?? false }
    }

    /// Whether the colour is anywhere in the rendering.
    func contains(_ matches: (NSColor) -> Bool) -> Bool {
        (0..<rep.pixelsHigh).contains { line($0, contains: matches) }
    }

    /// The first line anything is painted on, and nil when nothing is.
    var top: Int? { (0..<rep.pixelsHigh).first { line($0, contains: Self.isPainted) } }
}

/// [LAW:verifiable-goals] Edit Widget offers what the build extracted into the extension's metadata, and an intent compiled
/// into two targets is extracted into both, so the built app is read, as `HelperBuildTests` reads its helper. Shortcuts
/// reads the same file; this holds the file's field, not what Shortcuts shows.
struct WidgetIntentMetadataTests {
    struct Metadata: Decodable {
        struct Action: Decodable {
            struct Parameter: Decodable {
                struct ValueType: Decodable {
                    struct LinkEnumeration: Decodable {
                        struct Wrapper: Decodable { let identifier: String }
                        let wrapper: Wrapper
                    }
                    let linkEnumeration: LinkEnumeration?
                }
                let name: String
                let valueType: ValueType
            }
            let isDiscoverable: Bool
            let parameters: [Parameter]
        }
        struct Enum: Decodable {
            struct Case: Decodable { let identifier: String }
            let identifier: String
            let cases: [Case]
        }
        let actions: [String: Action]
        let enums: [Enum]
    }

    static func metadata(of bundle: URL) throws -> Metadata {
        let file = bundle.appending(path: "Contents/Resources/Metadata.appintents/extract.actionsdata")
        return try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: file))
    }

    static let app = Bundle.main.bundleURL
    static let widgets = app.appending(path: "Contents/PlugIns/OrangeDrinkWidgets.appex")

    @Test func editWidgetOffersTheStyleAndItsThreeCases() throws {
        let metadata = try Self.metadata(of: Self.widgets)
        let parameters = try #require(metadata.actions["AllBatteriesIntent"]).parameters
        #expect(parameters.map(\.name) == ["style"])
        #expect(parameters.map(\.valueType.linkEnumeration?.wrapper.identifier) == ["WidgetStyle"])
        let style = try #require(metadata.enums.first { $0.identifier == "WidgetStyle" })
        #expect(style.cases.map(\.identifier) == WidgetStyle.allCases.map(\.rawValue))
    }

    @Test(arguments: [app, widgets]) func theSettingsAreNotAnActionOfTheirOwn(bundle: URL) throws {
        #expect(try #require(Self.metadata(of: bundle).actions["AllBatteriesIntent"]).isDiscoverable == false)
    }
}
