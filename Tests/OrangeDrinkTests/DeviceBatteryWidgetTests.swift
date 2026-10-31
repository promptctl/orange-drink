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
        guard case .running(let devices) = try WidgetShelf.read(.devices, from: shelf).get() else { return nil }
        return devices.first { $0.address == address }?.level?.percent
    }

    // MARK: the shelf

    @Test func theWidgetReadsEachDevicesLevelAfterEveryChange() async throws {
        let reloads = Reloads()
        let publisher = ShelfPublisher<[WidgetDevice]>(item: .devices, directory: shelf) { if $0 == .deviceBattery { reloads.count += 1 } }
        let (changed, signal) = AsyncStream.makeStream(of: Void.self)
        var next = changed.makeAsyncIterator()
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events, onChange: { publisher.publish(WidgetDevice.list($0)); signal.yield() })

        send.yield(.reported(Self.iPhone))
        send.yield(.reported(Self.earbuds(54)))
        _ = await next.next()
        _ = await next.next()
        #expect(try levelRead("AA") == 95)
        #expect(try levelRead("BB") == 54)

        send.yield(.reported(Self.earbuds(50)))
        _ = await next.next()
        #expect(try levelRead("AA") == 95)
        #expect(try levelRead("BB") == 50)
        // One write per change of what the widgets draw: both arrivals and the earbuds' step.
        #expect(reloads.count == 3)
        _ = model
    }

    @Test func anEndedDeviceStreamEmptiesTheShelfInsteadOfFreezingItsLevels() async throws {
        let publisher = ShelfPublisher<[WidgetDevice]>(item: .devices, directory: shelf) { _ in }
        let (changed, signal) = AsyncStream.makeStream(of: Void.self)
        var next = changed.makeAsyncIterator()
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events, onChange: { publisher.publish(WidgetDevice.list($0)); signal.yield() },
                                 onEnded: { publisher.publish(WidgetDevice.list(DeviceList())); signal.yield() })
        send.yield(.reported(Self.iPhone))
        _ = await next.next()
        #expect(try levelRead("AA") == 95)

        send.finish()
        _ = await next.next()
        #expect(try levelRead("AA") == nil)
        #expect(model.failure != nil)
    }

    @Test func aDevicesModelTornDownIsNotAnEndedStreamAndLeavesTheShelfAlone() async throws {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let ended = Ended()
        var model: DevicesModel? = DevicesModel(events: events, onEnded: { ended.count += 1 })
        send.yield(.reported(Self.iPhone))
        model = nil
        send.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ended.count == 0)
        _ = model
    }

    @Test func theShelfLogsNeitherADevicesNameNorItsAddress() {
        let device = WidgetDevice(address: "AA-BB", name: "Brandon's iPhone", kind: .phone, level: BatteryLevel(percent: 80, approximate: false))
        let line = String(describing: Shelved.running([device]))
        #expect(!line.contains("Brandon") && !line.contains("AA-BB"))
        #expect(line.contains("80%"))
    }

    @Test func aDeviceThatDisconnectsLeavesTheShelfAndTheAppQuittingSaysSo() async throws {
        let publisher = ShelfPublisher<[WidgetDevice]>(item: .devices, directory: shelf) { _ in }
        var list = DeviceList()
        list.apply(.reported(Self.iPhone))
        publisher.publish(WidgetDevice.list(list))
        list.apply(.gone(Self.iPhone.id))
        publisher.publish(WidgetDevice.list(list))
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
        #expect(WidgetDevice.list(list) == [
            WidgetDevice(address: "CC", name: "iPad", kind: .tablet, level: BatteryLevel(percent: 40, approximate: true)),
            WidgetDevice(address: "BB", name: "Earbuds", kind: .accessory, level: BatteryLevel(percent: 54, approximate: false)),
            WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 95, approximate: false)),
            WidgetDevice(address: "DD", name: "Speaker", kind: .accessory, level: nil),
        ])
    }

    // MARK: the settings

    @Test func theSettingsOfferTheConnectedDevicesAndNothingWhileTheAppIsNotRunning() {
        let devices = [WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: nil)]
        #expect(WidgetDevices.choices(in: .running(devices)) == devices)
        #expect(WidgetDevices.choices(in: .appNotRunning).isEmpty)
    }

    @Test func aChosenDeviceThatIsGoneStillResolvesToNothing() {
        let phone = WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: nil)
        let resolved = WidgetDevices.resolve(["AA", "ZZ"], in: .running([phone]))
        #expect(resolved.map(\.address) == ["AA", "ZZ"])
        #expect(resolved.map(\.device) == [phone, nil])
    }

    // MARK: the drawing

    static func entry(_ shelf: Result<Shelved<[WidgetDevice]>, any Error>, chosen: String?) -> DeviceBatteryEntry {
        DeviceBatteryEntry(date: .now, shelf: shelf, chosen: chosen)
    }

    static func render(_ widget: DeviceBatteryView, size: CGSize) throws -> RingPixels {
        let renderer = ImageRenderer(content: widget.environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
        renderer.scale = 1
        return try RingPixels(#require(renderer.cgImage))
    }

    @Test func theWidgetDeclaresSmallMediumAndLarge() {
        #expect(WidgetFamilies.deviceBattery == [.systemSmall, .systemMedium, .systemLarge])
    }

    @Test(arguments: widgetSizes) func eachWidgetFillsItsArcClockwiseFromTheTopAsFarAsItsOwnDevicesLevel(family: WidgetFamily, size: CGSize) throws {
        let devices = WidgetDevice.list({ var list = DeviceList(); list.apply(.swept([Self.iPhone, Self.earbuds(54)])); return list }())
        func filled(_ address: String) throws -> Double {
            let view = DeviceBatteryView(entry: Self.entry(.success(.running(devices)), chosen: address), appName: "Orange Drink", family: family)
            return try Self.render(view, size: size).filledFraction
        }
        let (phone, buds) = (try filled("AA"), try filled("BB"))
        #expect(abs(phone - 0.95) < 0.03, "the iPhone filled \(phone)")
        #expect(abs(buds - 0.54) < 0.03, "the earbuds filled \(buds)")
    }

    @Test func aDeviceThatIsGoneTheAppNotRunningAndAnUnreadDeviceDrawWhatTheySay() throws {
        let unread = WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: nil)
        func texts(_ shelf: Result<Shelved<[WidgetDevice]>, any Error>, chosen: String?) throws -> [String] {
            try DeviceBatteryView(entry: Self.entry(shelf, chosen: chosen), appName: "Orange Drink", family: .systemSmall).inspect().findAll(ViewType.Text.self).map { try $0.string() }
        }
        #expect(try texts(.success(.running([unread])), chosen: "ZZ") == ["Not connected"])
        #expect(try texts(.success(.appNotRunning), chosen: "AA") == ["Open Orange Drink"])
        #expect(try texts(.failure(ShelfError.noGroupEntitlement), chosen: "AA") == ["Open Orange Drink"])
        #expect(try texts(.success(.running([unread])), chosen: nil) == ["Choose a device: right-click → Edit Widget"])
        #expect(try texts(.success(.running([unread])), chosen: "AA") == ["–"])
        let estimate = WidgetDevice(address: "AA", name: "iPhone", kind: .phone, level: BatteryLevel(percent: 40, approximate: true))
        #expect(try texts(.success(.running([estimate])), chosen: "AA") == ["~40%"])
    }
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

    /// Whether any pixel near the given point, within a share of the ring's radius, is of a colour.
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
}

@MainActor private final class Ended { var count = 0 }
