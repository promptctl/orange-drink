import AppKit
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the status item looks like for a
// reading: how full the outline is, what is printed in it, and what colour it is. The
// image is judged by its pixels, not by how it was drawn.
@Suite struct BatteryIndicatorDrawing {
    typealias Events = BatteryEvents

    static func indicator(_ powerSource: [String: Any], percent: Int) throws -> BatteryIndicator {
        BatteryIndicator(try Events.reading(powerSource, percent: percent))
    }
    static func discharging(_ percent: Int) throws -> BatteryIndicator {
        try indicator(Events.Fixtures.discharging(timeToEmpty: 192), percent: percent)
    }
    static func charging(_ percent: Int) throws -> BatteryIndicator {
        try indicator(Events.Fixtures.charging(timeToFull: 82), percent: percent)
    }

    @Test func printsThePercentInsideAnOutlineFilledToIt() throws {
        let indicator = try Self.discharging(75)
        #expect(indicator.label == "75")
        #expect(indicator.fill == 0.75)
        #expect(indicator.tint == .neutral)
    }

    @Test func tintFollowsChargingThenLowThenCritical() throws {
        #expect(try Self.charging(75).tint == .green)
        #expect(try Self.charging(3).tint == .green)
        #expect(try Self.discharging(20).tint == .orange)
        #expect(try Self.discharging(21).tint == .neutral)
        #expect(try Self.discharging(5).tint == .red)
        #expect(try Self.discharging(6).tint == .orange)
    }

    @Test func pluggedInAndHeldNotChargingIsNeutral() throws {
        #expect(try Self.indicator(Events.Fixtures.onACNotCharging(charged: false), percent: 80).tint == .neutral)
    }

    /// The pixels: fill extent across the outline, and the colour of what is filled, rendered
    /// as a light menu bar and as a dark one.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theImageIsFilledToTheChargeInTheTintColour(appearance: NSAppearance.Name) throws {
        let cases: [(BatteryIndicator, Pixels.Hue)] = [
            (try Self.charging(75), .green),
            (try Self.discharging(20), .orange),
            (try Self.discharging(5), .red),
        ]
        for (indicator, hue) in cases {
            let pixels = Pixels(indicator.image, appearance: appearance)
            let extent = try #require(pixels.fillExtent(of: hue), "\(indicator.tint) never painted \(hue)")
            #expect(abs(extent - indicator.fill) < 0.06, "\(indicator.label)% filled to \(extent)")
        }
    }

    @Test func neutralIsATemplateSoTheMenuBarTintsItAndTintedIsNot() throws {
        #expect(try Self.discharging(75).image.isTemplate)
        #expect(try Self.charging(75).image.isTemplate == false)
    }
}

/// A rendered status item image sampled at 2x.
struct Pixels {
    enum Hue { case green, orange, red }

    let width: Int, height: Int
    private let rep: NSBitmapImageRep

    init(_ image: NSImage, appearance: NSAppearance.Name) {
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

    /// The rightmost painted column of `hue`, over the width of the widest run of it in the
    /// outline: the fraction of the outline that is filled.
    func fillExtent(of hue: Hue) -> Double? {
        var columns: [Int] = []
        for x in 0..<width where (0..<height).contains(where: { matches(x, $0, hue) }) { columns.append(x) }
        guard let first = columns.first, let last = columns.last else { return nil }
        return Double(last - first + 1) / Double(interiorWidth)
    }

    /// The interior is a known fraction of the canvas; see BatteryIndicator.interior.
    private var interiorWidth: Int { Int((BatteryIndicator.interior.width * 2).rounded()) }

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
