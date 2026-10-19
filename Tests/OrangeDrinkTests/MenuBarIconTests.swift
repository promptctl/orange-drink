import AppKit
import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the status item looks like for a
// reading: how full the outline is, what is printed in it, and what colour it is. The
// image is judged by its pixels, not by how it was drawn.
@Suite struct MenuBarIconDrawing {
    typealias Events = BatteryEvents

    static func reading(_ powerSource: [String: Any], percent: Int) throws -> BatteryReading {
        try Events.reading(powerSource, percent: percent)
    }
    static func discharging(_ percent: Int) throws -> BatteryReading {
        try reading(Events.Fixtures.discharging(timeToEmpty: 192), percent: percent)
    }
    static func charging(_ percent: Int) throws -> BatteryReading {
        try reading(Events.Fixtures.charging(timeToFull: 82), percent: percent)
    }
    static func icon(_ reading: BatteryReading, _ edit: (inout MenuBarIconConfig) -> Void = { _ in }) -> MenuBarIcon {
        var config = MenuBarIconConfig()
        edit(&config)
        return MenuBarIcon(reading, config, on: .dark)
    }
    static func pixels(_ icon: MenuBarIcon) -> Pixels { Pixels(icon.image, scale: icon.size.scale) }

    @Test func indicatorPrintsThePercentInsideAnOutlineFilledToIt() throws {
        let battery = try #require(Self.icon(try Self.discharging(40)).battery)
        #expect(battery.text == "40")
        #expect(battery.fill == 0.4)
        #expect(battery.tint == .neutral)
    }

    @Test func tintFollowsChargingThenLowThenCritical() throws {
        func tint(_ reading: BatteryReading) throws -> BatteryIndicator.Tint { try #require(Self.icon(reading).battery).tint }
        #expect(try tint(Self.charging(75)) == .green)
        #expect(try tint(Self.charging(3)) == .green)
        #expect(try tint(Self.discharging(20)) == .orange)
        #expect(try tint(Self.discharging(21)) == .neutral)
        #expect(try tint(Self.discharging(5)) == .red)
        #expect(try tint(Self.discharging(6)) == .orange)
        #expect(try tint(Self.reading(Events.Fixtures.onACNotCharging(charged: false), percent: 80)) == .neutral)
    }

    @Test func statusColorsOffKeepsChargingAndLowNeutralAndCriticalRed() throws {
        func tint(_ reading: BatteryReading) throws -> BatteryIndicator.Tint {
            try #require(Self.icon(reading) { $0.statusColors = false }.battery).tint
        }
        #expect(try tint(Self.charging(75)) == .neutral)
        #expect(try tint(Self.discharging(15)) == .neutral)
        #expect(try tint(Self.discharging(4)) == .red)
    }

    @Test(arguments: [MenuBarIconConfig.Style.batteryIndicator, .minimal])
    func theImageIsFilledToTheChargeInTheTintColour(style: MenuBarIconConfig.Style) throws {
        let cases: [(BatteryReading, Pixels.Hue)] = [
            (try Self.charging(75), .green), (try Self.discharging(20), .orange), (try Self.discharging(5), .red),
        ]
        for (reading, hue) in cases {
            let icon = Self.icon(reading) { $0.style = style }
            let extent = try #require(Self.pixels(icon).fillExtent(of: hue), "nothing painted \(hue)")
            #expect(abs(extent - icon.battery!.fill) < 0.06, "\(reading.chargePercent)% filled to \(extent)")
        }
    }

    @Test func minimalFillsDifferentlyAtDifferentChargesAndLogoDoesNot() throws {
        let (low, high) = (try Self.discharging(40), try Self.discharging(90))
        let minimal = { (reading: BatteryReading) in Self.pixels(Self.icon(reading) { $0.style = .minimal; $0.display = .iconOnly }) }
        #expect(minimal(low).bytes != minimal(high).bytes)
        let logo = { (reading: BatteryReading) in Self.pixels(Self.icon(reading) { $0.style = .logo }) }
        #expect(logo(low).bytes == logo(high).bytes)
        #expect(Self.icon(low) { $0.style = .logo }.battery == nil)
    }

    @Test(arguments: [MenuBarIconConfig.Style.batteryIndicator, .minimal])
    func eachDisplayDrawsADifferentImage(style: MenuBarIconConfig.Style) throws {
        let reading = try Self.discharging(40)
        let images = [MenuBarIconConfig.Display.percentage, .timeRemaining, .iconOnly].map { display in
            Self.pixels(Self.icon(reading) { $0.style = style; $0.display = display }).bytes
        }
        #expect(Set(images).count == 3)
    }

    @Test func timeRemainingPrintsTheEstimateAndADashWithoutOne() throws {
        func text(_ powerSource: [String: Any]) throws -> String? {
            try Self.icon(Self.reading(powerSource, percent: 40)) { $0.display = .timeRemaining }.battery?.text
        }
        #expect(try text(Events.Fixtures.discharging(timeToEmpty: 192)) == "3:12")
        #expect(try text(Events.Fixtures.charging(timeToFull: 82)) == "1:22")
        #expect(try text(Events.Fixtures.onACNotCharging(charged: false)) == "–")
    }

    @Test func darkDrawsADarkerGlyphThanLight() throws {
        for style in [MenuBarIconConfig.Style.batteryIndicator, .minimal, .logo] {
            let reading = try Self.discharging(40)
            let light = Self.pixels(Self.icon(reading) { $0.style = style; $0.color = .light })
            let dark = Self.pixels(Self.icon(reading) { $0.style = style; $0.color = .dark })
            #expect(dark.glyphBrightness < light.glyphBrightness, "\(style)")
        }
    }

    @Test func everySizeAboveStandardDrawsALargerImage() throws {
        let reading = try Self.discharging(40)
        for style in [MenuBarIconConfig.Style.batteryIndicator, .minimal, .logo] {
            let standard = Self.icon(reading) { $0.style = style }.image.size
            for size in MenuBarIconConfig.Size.allCases where size != .standard {
                let larger = Self.icon(reading) { $0.style = style; $0.size = size }.image.size
                #expect(larger.width > standard.width && larger.height > standard.height, "\(style) \(size)")
            }
        }
    }
}

/// A rendered status item image sampled at 2x.
struct Pixels {
    enum Hue { case green, orange, red }

    let width: Int, height: Int
    let scale: Double
    private let rep: NSBitmapImageRep

    init(_ image: NSImage, scale: Double = 1, appearance: NSAppearance.Name = .aqua) {
        self.scale = scale
        width = Int(image.size.width * 2); height = Int(image.size.height * 2)
        rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Every pixel, so two images are the same image exactly when these are equal.
    var bytes: Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * height) }

    /// How bright the glyph is: the mean brightness of its opaque pixels.
    var glyphBrightness: Double {
        let lit = (0..<width).flatMap { x in (0..<height).compactMap { y in rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) } }
            .filter { $0.alphaComponent > 0.5 }
        return lit.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }.reduce(0, +) / Double(lit.count)
    }

    /// The rightmost painted column of `hue`, over the width of the widest run of it in the
    /// outline: the fraction of the outline that is filled.
    func fillExtent(of hue: Hue) -> Double? {
        var columns: [Int] = []
        for x in 0..<width where (0..<height).contains(where: { matches(x, $0, hue) }) { columns.append(x) }
        guard let first = columns.first, let last = columns.last else { return nil }
        return Double(last - first + 1) / Double(interiorWidth)
    }

    /// The interior is a known fraction of the canvas; see BatteryIndicator.interior.
    private var interiorWidth: Int { Int((MenuBarIcon.interior.width * 2 * scale).rounded()) }

    private func matches(_ x: Int, _ y: Int, _ hue: Hue) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.9 else { return false }
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        switch hue {
        case .green: return g > 0.5 && g > r + 0.25 && g > b + 0.25
        case .orange: return r > 0.7 && g > 0.3 && g < 0.75 && b < 0.3 && r > g + 0.2
        case .red: return r > 0.7 && g < 0.35 && b < 0.35
        }
    }
}
