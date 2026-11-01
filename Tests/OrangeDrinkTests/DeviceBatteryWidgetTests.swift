import AppKit
import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a Device Battery widget reads off the shelf after each change
// the app sees, and what it draws from that: through the widget's own read path and the real view, from a shelf in
// a directory of the test's own.
let widgetSizes: [(WidgetFamily, CGSize)] = [
    (.systemSmall, CGSize(width: 158, height: 158)),
    (.systemMedium, CGSize(width: 338, height: 158)),
    (.systemLarge, CGSize(width: 338, height: 354)),
]

@MainActor @Suite(.timeLimit(.minutes(1))) final class DeviceBatteryWidgetTests {
    static let iPhone = Device(id: DeviceID(address: "AA"), name: "iPhone", kind: .phone,
                               levels: .single(BatteryLevel(percent: 95, approximate: false)))
    static func earbuds(_ percent: Int) -> Device {
        Device(id: DeviceID(address: "BB"), name: "Earbuds", kind: .accessory,
               levels: .earbuds(left: BatteryLevel(percent: percent, approximate: false), right: nil, case: BatteryLevel(percent: 80, approximate: false)))
    }

    final class Reloads { var count = 0 }

    let shelf = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: shelf)
    }

    /// What the widget reads for a device, through its own read path.
    func levelRead(_ address: String) throws -> Int? {
        guard case .running(.connected(let devices, _)) = try WidgetShelf.read(.devices, from: shelf).get() else { return nil }
        return devices.first { $0.address == address }?.level?.percent
    }

    // MARK: the shelf

    @Test func theWidgetReadsEachDevicesLevelAfterEveryChange() async throws {
        let reloads = Reloads()
        let publisher = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { if $0 == .deviceBattery { reloads.count += 1 } }
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = try DevicesModel(events: events, shelf: publisher)

        send.yield(.swept([Self.iPhone]))
        #expect(try await eventually { try levelRead("AA") == 95 })
        send.yield(.reported(Self.earbuds(54)))
        #expect(try await eventually { try levelRead("BB") == 54 })
        #expect(try levelRead("AA") == 95)

        send.yield(.reported(Self.earbuds(50)))
        #expect(try await eventually { try levelRead("BB") == 50 })
        #expect(try levelRead("AA") == 95)
        // One write per change of what the widgets draw: the launch, both arrivals and the earbuds' step.
        #expect(reloads.count == 4)
        _ = model
    }

    @Test func anEndedDeviceStreamTakesItsLevelsOffTheShelfInsteadOfFreezingThem() async throws {
        let publisher = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { _ in }
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = try DevicesModel(events: events, shelf: publisher)
        send.yield(.swept([Self.iPhone]))
        #expect(try await eventually { try levelRead("AA") == 95 })

        send.finish()
        #expect(try await eventually { try WidgetShelf.read(.devices, from: shelf).get() == .running(.unread(.ended)) })
        _ = model
    }

    @Test func aDevicesModelTornDownIsNotAnEndedStreamAndLeavesTheShelfAlone() async throws {
        let publisher = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { _ in }
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        var model: DevicesModel? = try DevicesModel(events: events, shelf: publisher)
        model = nil
        send.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try WidgetShelf.read(.devices, from: shelf).get() == .running(.unread(.waiting)))
        _ = model
    }

    @Test func theShelfLogsNeitherADevicesNameNorItsAddress() {
        let device = WidgetDevice(address: "AA-BB", name: "Brandon's iPhone", kind: .phone, level: BatteryLevel(percent: 80, approximate: false))
        let line = String(describing: Shelved.running(WidgetDevices.connected([device], pinned: [])))
        #expect(!line.contains("Brandon") && !line.contains("AA-BB"))
        #expect(line.contains("80%"))
    }

    @Test func aDeviceThatDisconnectsLeavesTheShelfAndTheAppQuittingSaysSo() async throws {
        let publisher = ShelfPublisher<WidgetDevices>(item: .devices, directory: shelf) { _ in }
        var list = DeviceList()
        list.apply(.swept([Self.iPhone]))
        publisher.publish(WidgetDevices(list, pinned: []))
        #expect(try levelRead("AA") == 95)
        list.apply(.gone(Self.iPhone.id))
        publisher.publish(WidgetDevices(list, pinned: []))
        #expect(try levelRead("AA") == nil)
        publisher.publishQuit()
        #expect(try WidgetShelf.read(.devices, from: shelf).get() == .appNotRunning)
    }

    @Test func eachRowBecomesItsWidgetDeviceWithTheLevelThePanelShows() throws {
        var list = DeviceList()
        list.apply(.swept([
            Self.iPhone,
            Device(id: DeviceID(address: "CC"), name: "iPad", kind: .tablet, levels: .single(BatteryLevel(percent: 40, approximate: true))),
            Device(id: DeviceID(address: "DD"), name: "Speaker", kind: .accessory, levels: .unread),
            Device(id: DeviceID(address: "EE"), name: "Mouse", kind: .accessory, levels: .none),
            Self.earbuds(54),
        ]))
        // Ranked as the panel ranks them: lowest first, unread last, a device with no battery absent; the case is never the level.
        #expect(WidgetDevices(list, pinned: []) == .connected([
            WidgetDevice(address: "CC", name: "iPad", kind: .tablet, level: BatteryLevel(percent: 40, approximate: true)),
            WidgetDevice(address: "BB", name: "Earbuds", kind: .accessory, level: BatteryLevel(percent: 54, approximate: false)),
            WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 95, approximate: false)),
            WidgetDevice(address: "DD", name: "Speaker", kind: .accessory, level: nil),
        ], pinned: []))
    }

    // MARK: the settings

    @Test func theSettingsOfferTheConnectedDevicesAndNothingWhileTheAppIsNotRunning() {
        let devices = [WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: nil)]
        #expect(WidgetDevices.choices(in: .running(.connected(devices, pinned: []))) == devices)
        #expect(WidgetDevices.choices(in: .running(.unread(.denied))).isEmpty)
        #expect(WidgetDevices.choices(in: .appNotRunning).isEmpty)
    }

    @Test func aChosenDeviceThatIsGoneStillResolvesToNothing() {
        let phone = WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: nil)
        let resolved = WidgetDevices.resolve(["AA", "ZZ"], in: .running(.connected([phone], pinned: [])))
        #expect(resolved.map(\.address) == ["AA", "ZZ"])
        #expect(resolved.map(\.device) == [phone, nil])
        // A list the app could not read keeps the widget's choice too.
        #expect(WidgetDevices.resolve(["AA"], in: .running(.unread(.denied))).map(\.address) == ["AA"])
    }

    // MARK: the drawing

    static func entry(_ shelf: Result<Shelved<WidgetDevices>, any Error>, chosen: String?) -> DeviceBatteryEntry {
        DeviceBatteryEntry(date: .now, shelf: shelf, chosen: chosen)
    }

    @Test func theWidgetDeclaresSmallMediumAndLarge() {
        #expect(WidgetFamilies.deviceBattery == [.systemSmall, .systemMedium, .systemLarge])
    }

    @Test(arguments: widgetSizes) func eachWidgetFillsItsArcClockwiseFromTheTopAsFarAsItsOwnDevicesLevel(family: WidgetFamily, size: CGSize) throws {
        let devices = WidgetDevices({ var list = DeviceList(); list.apply(.swept([Self.iPhone, Self.earbuds(54)])); return list }(), pinned: [])
        func filled(_ address: String) throws -> Double {
            let view = DeviceBatteryView(entry: Self.entry(.success(.running(devices)), chosen: address), appName: "Orange Drink", family: family)
            return try RingPixels(widgetImage(view, size: size, scheme: .light, scale: 1)).filledFraction
        }
        let (phone, buds) = (try filled("AA"), try filled("BB"))
        #expect(abs(phone - 0.95) < 0.03, "the iPhone filled \(phone)")
        #expect(abs(buds - 0.54) < 0.03, "the earbuds filled \(buds)")
    }

    @Test func aDeviceThatIsGoneTheAppNotRunningAndAnUnreadDeviceDrawWhatTheySay() throws {
        let unread = WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: nil)
        func texts(_ shelf: Result<Shelved<WidgetDevices>, any Error>, chosen: String?) throws -> [String] {
            try DeviceBatteryView(entry: Self.entry(shelf, chosen: chosen), appName: "Orange Drink", family: .systemSmall).inspect().findAll(ViewType.Text.self).map { try $0.string() }
        }
        #expect(try texts(.success(.running(.connected([unread], pinned: []))), chosen: "ZZ") == ["Not connected"])
        #expect(try texts(.success(.appNotRunning), chosen: "AA") == ["Open Orange Drink"])
        #expect(try texts(.failure(ShelfError.noGroupEntitlement), chosen: "AA") == ["Open Orange Drink"])
        #expect(try texts(.success(.running(.connected([unread], pinned: []))), chosen: nil) == ["Choose a device: right-click → Edit Widget"])
        #expect(try texts(.success(.running(.connected([unread], pinned: []))), chosen: "AA") == ["–"])
        let estimate = WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 40, approximate: true))
        #expect(try texts(.success(.running(.connected([estimate], pinned: []))), chosen: "AA") == ["~40%"])
    }
}

@MainActor func widgetImage(_ widget: some View, size: CGSize, scheme: ColorScheme, scale: CGFloat) throws -> CGImage {
    let renderer = ImageRenderer(content: widget.environment(\.colorScheme, scheme).frame(width: size.width, height: size.height))
    renderer.scale = scale
    return try #require(renderer.cgImage)
}

/// A rendered ring, read back: where it is, and how far round from the top its arc runs.
struct RingPixels {
    private struct Body { var size = 0, minX = Int.max, maxX = 0, minY = Int.max, maxY = 0 }

    private let rep: NSBitmapImageRep
    private let centre: CGPoint
    private let radius: Double

    /// The track is part-transparent and the arc opaque; the ring is the largest connected body of either: its glyph, percentage and name are
    /// ink too, but each is a body of its own, so the ring's bounding box is the ring's. A charging ring's top is its bolt's gap, so its
    /// centre is measured from its bottom edge.
    init(_ image: CGImage) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        self.rep = rep
        let (width, height) = (rep.pixelsWide, rep.pixelsHigh)
        let painted = (0..<width * height).map { (rep.colorAt(x: $0 % width, y: $0 / width)?.alphaComponent ?? 0) > 0.1 }
        var seen = [Bool](repeating: false, count: width * height)
        var largest = Body()
        for start in 0..<painted.count where painted[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var body = Body()
            while let at = stack.popLast() {
                let (x, y) = (at % width, at / width)
                body = Body(size: body.size + 1, minX: min(body.minX, x), maxX: max(body.maxX, x), minY: min(body.minY, y), maxY: max(body.maxY, y))
                for (dx, dy) in [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] {
                    let (nx, ny) = (x + dx, y + dy)
                    guard nx >= 0, nx < width, ny >= 0, ny < height, painted[ny * width + nx], !seen[ny * width + nx] else { continue }
                    seen[ny * width + nx] = true
                    stack.append(ny * width + nx)
                }
            }
            if body.size > largest.size { largest = body }
        }
        try #require(largest.size > 0, "no ring in the rendering")
        let across = Double(largest.maxX - largest.minX)
        centre = CGPoint(x: Double(largest.minX + largest.maxX) / 2, y: Double(largest.maxY) - across / 2)
        // The stroke is centred on a circle a tenth narrower than its outer edge, which the bounding box measures.
        radius = (across + 1) / 2 / 1.1
    }

    /// The ring's width, along the circle its stroke is centred on: what the reference's "38 pt across" measures.
    var across: Double { radius * 2 }

    private func colour(_ x: Int, _ y: Int) -> NSColor? { rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }

    /// Dark ink on a light widget.
    static func isInk(_ colour: NSColor) -> Bool { colour.alphaComponent > 0.9 && colour.brightnessComponent < 0.4 }

    /// How far, as a fraction of the way round, the arc runs unbroken clockwise from twelve o'clock.
    var filledFraction: Double { filledFraction(from: 0, isArc: Self.isInk) }

    /// How far round the arc reaches, walking clockwise from `start`, a fraction of the way round.
    func filledFraction(from start: Double, isArc: (NSColor) -> Bool) -> Double {
        let steps = 720
        let first = Int(start * Double(steps))
        let run = (first..<steps).prefix { step in
            let angle = Double(step) / Double(steps) * 2 * .pi
            return colour(Int((centre.x + radius * sin(angle)).rounded()), Int((centre.y - radius * cos(angle)).rounded())).map(isArc) ?? false
        }
        return Double(first + run.count) / Double(steps)
    }

    /// Whether any pixel within `reach` pixels of the given point is of a colour.
    private func anyPixel(aroundX x: Double, y: Double, within reach: Double, _ matches: (NSColor) -> Bool) -> Bool {
        let (xs, ys) = (max(0, Int(x - reach))...min(rep.pixelsWide - 1, Int(x + reach)), max(0, Int(y - reach))...min(rep.pixelsHigh - 1, Int(y + reach)))
        return ys.contains { y in xs.contains { x in colour(x, y).map(matches) ?? false } }
    }

    /// Whether the colour is anywhere in the rendering.
    func contains(_ matches: (NSColor) -> Bool) -> Bool {
        anyPixel(aroundX: Double(rep.pixelsWide) / 2, y: Double(rep.pixelsHigh) / 2, within: Double(max(rep.pixelsWide, rep.pixelsHigh)), matches)
    }

    /// Whether the colour is in the ring's twelve o'clock gap, where the bolt sits: nearer the top than the arc reaches.
    func containsAtTwelve(_ matches: (NSColor) -> Bool) -> Bool {
        anyPixel(aroundX: centre.x, y: centre.y - radius, within: radius * 0.15, matches)
    }

    /// Whether the ring is cut open either side of twelve o'clock, beyond the bolt's own width. An unbroken
    /// arc also has its colour at twelve, so this is what makes that colour the bolt's.
    var isOpenAtTwelve: Bool {
        [-0.2, 0.2].allSatisfy { side in
            let (x, y) = (Int((centre.x + radius * side).rounded()), Int((centre.y - radius).rounded()))
            return (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.1
        }
    }
}

