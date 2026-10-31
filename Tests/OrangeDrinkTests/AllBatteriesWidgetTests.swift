import AppKit
import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is which batteries the widget lists, what it draws for them at each
// size, and which widgets redraw when the app changes a file, from a shelf in a directory of the test's own.
let allBatteriesSizes = widgetSizes + [(.systemExtraLarge, CGSize(width: 715, height: 354))]

@MainActor @Suite(.timeLimit(.minutes(1))) final class AllBatteriesWidgetTests {
    /// WidgetKit keeps this margin inside a widget: a rendering is the content area.
    static let margin: CGFloat = 16

    static let charging = MacBattery.level(percent: 80, charging: true)
    static let onBattery = MacBattery.level(percent: 79, charging: false)

    static func device(_ address: String, _ percent: Int, kind: DeviceKind = .accessory, approximate: Bool = false) -> WidgetDevice {
        WidgetDevice(address: address, name: "Device \(address)", kind: kind, level: BatteryLevel(percent: percent, approximate: approximate))
    }

    static let twentyLevels = Array(stride(from: 21, through: 97, by: 4))
    static let twenty = twentyLevels.map { device("\($0)", $0) }

    /// The reference's other three rings: phone, wireless arcs, tablet.
    static let three = [device("AA", 95, kind: .phone), device("BB", 54), device("CC", 40, kind: .tablet)]

    static func entry(_ mac: MacBattery, _ devices: [WidgetDevice]) -> AllBatteriesEntry {
        AllBatteriesEntry(date: .now, mac: .success(.running(mac)), devices: .success(.running(devices)))
    }

    static func view(_ entry: AllBatteriesEntry, _ family: WidgetFamily = .systemSmall) -> AllBatteriesView {
        AllBatteriesView(entry: entry, appName: "Orange Drink", family: family)
    }

    /// What the widget says, in reading order.
    static func texts(_ entry: AllBatteriesEntry, _ family: WidgetFamily = .systemSmall) throws -> [String] {
        try view(entry, family).inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: the list

    @Test func theMacComesFirstThenTheDevicesInThePanelsOrder() {
        let list = AllBatteries.list(mac: Self.charging, devices: Self.three)
        #expect(list == [
            WidgetBattery(glyph: "laptopcomputer", level: BatteryLevel(percent: 80, approximate: false), charging: true),
            WidgetBattery(glyph: "iphone", level: BatteryLevel(percent: 95, approximate: false), charging: false),
            WidgetBattery(glyph: "dot.radiowaves.left.and.right", level: BatteryLevel(percent: 54, approximate: false), charging: false),
            WidgetBattery(glyph: "ipad", level: BatteryLevel(percent: 40, approximate: false), charging: false),
        ])
    }

    @Test func aMacWithNoBatteryIsNotListedAndOneWithNoReadingIsListedEmpty() {
        let devices = [Self.device("AA", 95, approximate: true)]
        #expect(AllBatteries.list(mac: .noBattery, devices: devices) == [WidgetBattery(devices[0])])
        for mac in [MacBattery.waiting, .ended] {
            let empty = WidgetBattery(glyph: "laptopcomputer", level: nil, charging: false)
            #expect(AllBatteries.list(mac: mac, devices: devices) == [empty, WidgetBattery(devices[0])])
        }
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

    // MARK: the drawing

    static func image(_ entry: AllBatteriesEntry, _ family: WidgetFamily, content size: CGSize) throws -> CGImage {
        let widget = view(entry, family).environment(\.colorScheme, .dark).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: widget)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// The four rings of a rendering at Small, in reading order.
    static func cells(_ entry: AllBatteriesEntry) throws -> [RingPixels] {
        let side = 158 - 2 * margin
        let image = try image(entry, .systemSmall, content: CGSize(width: side, height: side))
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
        #expect(cells[0].containsAtTwelve(Self.isGreen))
        Self.expectOtherRingsAreGrey(cells)
    }

    @Test func onBatteryTheMacsArcIsGreyWithNoBolt() throws {
        let cells = try Self.cells(Self.entry(Self.onBattery, Self.three))
        let filled = cells[0].filledFraction(from: 0, isArc: Self.isGrey)
        #expect(abs(filled - 0.79) < 0.03, "the Mac's ring filled \(filled)")
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
        func open(_ entry: AllBatteriesEntry) throws { #expect(try Self.texts(entry) == ["Open Orange Drink"]) }
        let running = Result<Shelved<[WidgetDevice]>, any Error>.success(.running(Self.three))
        try open(AllBatteriesEntry(date: .now, mac: .success(.appNotRunning), devices: running))
        try open(AllBatteriesEntry(date: .now, mac: .failure(ShelfError.noGroupEntitlement), devices: running))
        try open(AllBatteriesEntry(date: .now, mac: .success(.running(Self.charging)), devices: .success(.appNotRunning)))
        try open(AllBatteriesEntry(date: .now, mac: .success(.running(Self.charging)), devices: .failure(ShelfError.noGroupEntitlement)))

        #expect(try Self.texts(Self.entry(.noBattery, [])) == ["No batteries"])
        #expect(try Self.texts(Self.entry(.noBattery, Self.three)) == ["95%", "54%", "40%"])
        // A cell has no room for Mac Battery's sentence, and a ring that stopped keeps the rings beside it on the widget.
        #expect(try Self.texts(Self.entry(.ended, Self.three)) == ["–", "95%", "54%", "40%"])
        #expect(try Self.texts(Self.entry(.waiting, Self.three)) == ["–", "95%", "54%", "40%"])
        #expect(try Self.texts(Self.entry(.noBattery, [Self.device("AA", 40, approximate: true)])) == ["~40%"])
    }

    // MARK: the shelf

    @Test func eachFileRedrawsTheWidgetsThatDrawItAndTheWidgetReadsBothFiles() throws {
        let shelf = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shelf) }
        var asked: [WidgetKind] = []
        let mac = ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { asked.append($0) }
        let devices = ShelfPublisher<[WidgetDevice]>(item: .devices, directory: shelf) { asked.append($0) }
        func reloads(_ change: () -> Void) -> [WidgetKind] {
            asked = []
            change()
            return asked
        }

        #expect(reloads { mac.publish(Self.charging) } == [.macBattery, .allBatteries])
        #expect(reloads { devices.publish(Self.three) } == [.deviceBattery, .allBatteries])
        #expect(reloads { mac.publish(Self.charging) } == [])
        #expect(reloads { devices.publish(Self.three) } == [])

        let shelved = AllBatteriesEntry(date: .now, mac: WidgetShelf.read(.macBattery, from: shelf), devices: WidgetShelf.read(.devices, from: shelf))
        #expect(try Self.texts(shelved) == ["80%", "95%", "54%", "40%"])

        #expect(reloads { mac.publish(Self.onBattery) } == [.macBattery, .allBatteries])
        #expect(reloads { mac.publishQuit() } == [.macBattery, .allBatteries])
        #expect(reloads { devices.publishQuit() } == [.deviceBattery, .allBatteries])
        let quit = AllBatteriesEntry(date: .now, mac: WidgetShelf.read(.macBattery, from: shelf), devices: WidgetShelf.read(.devices, from: shelf))
        #expect(try Self.texts(quit) == ["Open Orange Drink"])
    }
}
