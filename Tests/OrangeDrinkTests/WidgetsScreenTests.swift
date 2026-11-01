import Foundation
import SwiftUI
import Testing
import ViewInspector
import WidgetKit
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the screen says, what its controls do to the preview, and what the
// preview draws, from the app's own models fed stand-in readings and devices, with no window.
@MainActor @Suite(.timeLimit(.minutes(1))) final class WidgetsScreenTests {
    /// The Mac at 80% charging and two simulated devices, as the models hold them.
    @MainActor struct Bed {
        let feed: AsyncThrowingStream<BatteryReading?, any Error>.Continuation
        let send: AsyncThrowingStream<DeviceEvent, any Error>.Continuation
        let battery: BatteryModel
        let devices: DevicesModel
        let settings: DeviceSettingsModel
        let screen: WidgetsScreen

        init() async throws {
            let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
            let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
            let battery = BatteryModel(readings: readings)
            let devices = DevicesModel(events: events)
            let settings = try DeviceSettingsModel(defaults: UserDefaults(suiteName: "WidgetsScreenTests.\(UUID())")!)
            (self.feed, self.send, self.battery, self.devices, self.settings) = (feed, send, battery, devices, settings)
            screen = WidgetsScreen(battery: battery, devices: devices, settings: settings)
            let charging = try BatteryHistoryTests.charging(80)
            feed.yield(charging)
            _ = await battery.state { if case .known(let held) = $0 { held == charging } else { false } }
            send.yield(.swept([Self.device("A", 95, .phone), Self.device("B", 54, .accessory)]))
            let swept = await eventually { DeviceRanking.rows(devices.list).count == 2 }
            try #require(swept)
        }

        static func device(_ address: String, _ percent: Int, _ kind: DeviceKind) -> Device {
            Device(id: DeviceID(address: address), name: "Device \(address)", kind: kind, levels: .single(BatteryLevel(percent: percent, approximate: false)))
        }

        func preview() throws -> WidgetPreview { try screen.inspect().find(WidgetPreview.self).actualView() }

        /// What the screen says, in reading order, with a sentence's bold marks left out.
        func texts() throws -> [String] {
            try screen.inspect().findAll(ViewType.Text.self).map { try $0.string().replacing("**", with: "") }
        }

        func press(_ button: String) throws { try screen.inspect().find(button: button).tap() }
    }

    /// What the rendered preview's widget draws at Small, in the grid's reading order: the Mac comes first. The widget
    /// alone, because `RingPixels` finds a ring by its alpha and the surface is opaque.
    static func macRing(_ preview: WidgetPreview) throws -> RingPixels {
        try #require(try AllBatteriesWidgetTests.cells(widgetImage(preview.widget, size: AllBatteriesWidgetTests.content(.systemSmall), scheme: .dark, scale: 2)).first)
    }

    // MARK: what it says

    @Test func theHeaderIsTheDesignDocs() {
        #expect(SettingsScreen.widgets.title.english == "Widgets")
        #expect(SettingsScreen.widgets.glyph == "square.grid.2x2.fill")
        #expect(SettingsScreen.widgets.subtitle(appName: "App")?.english == "Put your batteries on the desktop and in Notification Center")
    }

    @Test func itHoldsEverySectionOfTheDesignDocWithTheAppsName() async throws {
        let texts = try await Bed().texts()
        for text in ["Widget Types", "Live preview", "All Batteries", "Mac Battery", "Device Battery", "Small", "Medium", "Large",
                     "Your Mac and all your devices in one widget. Small, medium, large and extra large: the bigger the size, the more devices fit.",
                     "What you can modify (right-click the widget → Edit Widget):",
                     "Devices: Automatic (as many as fit), Custom (your order), or Same as menu bar", "Style: Rings, List or Bars",
                     "Show device names · Include this Mac", "Appearance: Color or Monochrome",
                     "Add a Widget", "1", "2", "3",
                     "Right-click your desktop and choose Edit Widgets…, or open Notification Center (click the clock) and scroll to the bottom.",
                     "Search for \(appName) and drag a widget wherever you like. Each size is its own entry in the gallery.",
                     "Right-click a placed widget → Edit Widget to choose devices, style and names. Click a widget to open \(appName).",
                     "Good to Know", "Every widget has its own settings",
                     "Right-click a placed widget → Edit Widget. That's where you choose the devices, the style, names, and which device a Device Battery widget shows. Add the same widget twice with different settings if you like."] {
            #expect(texts.contains(text), "the screen does not say: \(text)")
        }
    }

    @Test func onlyAllBatteriesIsExplained() async throws {
        let bed = try await Bed()
        for type in ["Mac Battery", "Device Battery"] {
            try bed.press(type)
            #expect(!(try bed.texts()).contains("What you can modify (right-click the widget → Edit Widget):"))
        }
        try bed.press("All Batteries")
        #expect(try bed.texts().contains("What you can modify (right-click the widget → Edit Widget):"))
    }

    // MARK: the pickers

    @Test func allBatteriesAndSmallStartSelected() async throws {
        let bed = try await Bed()
        let types = try bed.screen.inspect().findAll(WidgetTypeButton.self).map { try $0.actualView() }
        #expect(types.map(\.kind) == [.allBatteries, .macBattery, .deviceBattery])
        #expect(types.map(\.isSelected) == [true, false, false])
        #expect(try bed.screen.inspect().find(SegmentedPills<WidgetPreviewSize>.self).actualView().selection == .small)
        #expect(try bed.screen.inspect().find(AllBatteriesView.self).actualView().family == .systemSmall)
    }

    @Test func choosingATypeChangesThePreviewToThatWidget() async throws {
        let bed = try await Bed()
        try bed.press("Mac Battery")
        #expect(throws: Never.self) { try bed.screen.inspect().find(MacBatteryView.self) }
        try bed.press("Device Battery")
        #expect(throws: Never.self) { try bed.screen.inspect().find(DeviceBatteryView.self) }
        try bed.press("All Batteries")
        #expect(throws: Never.self) { try bed.screen.inspect().find(AllBatteriesView.self) }
    }

    /// The table the widget tests render at is the reference for a widget's real size.
    @Test(arguments: zip(WidgetPreviewSize.allCases, widgetSizes)) func choosingASizeRendersThePreviewAtThatSize(size: WidgetPreviewSize, expected: (WidgetFamily, CGSize)) async throws {
        let bed = try await Bed()
        try bed.press(size.title.english)
        #expect(try bed.screen.inspect().find(AllBatteriesView.self).actualView().family == expected.0)
        for type in ["All Batteries", "Mac Battery", "Device Battery"] {
            try bed.press(type)
            let renderer = ImageRenderer(content: try bed.preview().environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(CGSize(width: image.width, height: image.height) == CGSize(width: expected.1.width * 2, height: expected.1.height * 2), "\(type)")
        }
    }

    @Test(arguments: WidgetPreviewSize.allCases) func deviceBatteryDrawsAtTheChosenSize(size: WidgetPreviewSize) async throws {
        let bed = try await Bed()
        try bed.press("Device Battery")
        try bed.press(size.title.english)
        #expect(try bed.screen.inspect().find(DeviceBatteryView.self).actualView().family == size.family)
    }

    // MARK: the preview

    @Test func thePreviewShowsTheLevelsThePanelShows() async throws {
        let bed = try await Bed()
        let panel = ConnectedDevices(bed.devices.list, settings: bed.settings.value).rows.map(\.percent)
        let drawn = try bed.screen.inspect().find(AllBatteriesView.self).findAll(ViewType.Text.self).map { try $0.string() }
        #expect(panel == ["54%", "95%"])
        #expect(drawn == ["80%"] + panel)
    }

    /// Hiding takes a device off the panel, as its label says. A placed widget keeps it, so the preview does.
    @Test func aDeviceHiddenFromThePanelStaysInThePreview() async throws {
        let bed = try await Bed()
        try bed.settings.update { $0.toggleHidden(DeviceID(address: "B")) }
        #expect(ConnectedDevices(bed.devices.list, settings: bed.settings.value).rows.map(\.percent) == ["95%"])
        #expect(try bed.screen.inspect().find(AllBatteriesView.self).findAll(ViewType.Text.self).map { try $0.string() } == ["80%", "54%", "95%"])
    }

    @Test func deviceBatteryPreviewsTheDeviceFirstInTheRanking() async throws {
        let bed = try await Bed()
        try bed.press("Device Battery")
        let drawn = try bed.screen.inspect().find(DeviceBatteryView.self).findAll(ViewType.Text.self).map { try $0.string() }
        #expect(drawn == ["54%"])
    }

    @Test func aDeviceThatChangesChangesThePreview() async throws {
        let bed = try await Bed()
        bed.send.yield(.swept([Bed.device("A", 95, .phone), Bed.device("B", 12, .accessory)]))
        #expect(await eventually { DeviceRanking.rows(bed.devices.list).first?.percent == "12%" })
        #expect(try bed.screen.inspect().find(AllBatteriesView.self).findAll(ViewType.Text.self).map { try $0.string() } == ["80%", "12%", "95%"])
    }

    /// `inspect()` draws the screen afresh, so only this says an open screen hears of a change.
    @Test func anOpenScreenHearsOfAReadingAndOfADevice() async throws {
        let bed = try await Bed()
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        var next = changes.makeAsyncIterator()
        func draw() throws {
            _ = try withObservationTracking { Result { try bed.preview() } } onChange: { change.yield() }.get()
        }

        try draw()
        bed.feed.yield(try BatteryHistoryTests.onBattery(79))
        #expect(await next.next() != nil)

        try draw()
        bed.send.yield(.swept([Bed.device("A", 12, .phone)]))
        #expect(await next.next() != nil)
    }

    /// The bolt's gap is cut out of the ring and must stop there. Read from both renderers, because they have disagreed
    /// about it: `ImageRenderer`, and a hosted view's own drawing, as a window's is. The inset leaves out the clipped corners.
    @Test func theSurfaceIsUnbrokenBehindTheChargingBolt() async throws {
        let bed = try await Bed()
        let size = WidgetPreviewSize.small.points
        let host = NSHostingView(rootView: try bed.preview().environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let hosted = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: hosted)
        let rendered = NSBitmapImageRep(cgImage: try widgetImage(bed.preview(), size: size, scheme: .dark, scale: 2))
        for (renderer, rep) in [("ImageRenderer", rendered), ("hosted", hosted)] {
            let inside = (rep.pixelsWide / 24)..<(rep.pixelsWide * 23 / 24)
            let holes = inside.flatMap { y in inside.filter { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 1 } }
            #expect(holes.isEmpty, "\(renderer) shows \(holes.count) pixels through the surface")
        }
    }

    @Test func aReadingOnBatteryWithTheScreenOpenTakesTheGreenAndTheBoltOffTheMac() async throws {
        let bed = try await Bed()
        let charging = try Self.macRing(bed.preview())
        #expect(charging.contains(AllBatteriesWidgetTests.isGreen))
        #expect(charging.isOpenAtTwelve)
        #expect(charging.containsAtTwelve(AllBatteriesWidgetTests.isGreen))

        let onBattery = try BatteryHistoryTests.onBattery(79)
        bed.feed.yield(onBattery)
        _ = await bed.battery.state { if case .known(let held) = $0 { held == onBattery } else { false } }

        let unplugged = try Self.macRing(bed.preview())
        let filled = unplugged.filledFraction(from: 0, isArc: AllBatteriesWidgetTests.isGrey)
        #expect(abs(filled - 0.79) < 0.03, "the Mac's ring filled \(filled)")
        #expect(!unplugged.contains(AllBatteriesWidgetTests.isGreen))
        #expect(!unplugged.isOpenAtTwelve)
    }
}
