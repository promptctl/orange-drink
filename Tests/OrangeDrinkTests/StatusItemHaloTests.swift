import AppKit
import QuartzCore
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] What the menu bar shows of the halo is the layer's state: whether it is
// there, what it holds, and how its opacity moves. These read that state off a bare CALayer and a
// stand-in button, with no window.
/// The status bar as the halo finds it: the button it holds now, which a test swaps out.
@MainActor private final class Bar {
    var button: NSStatusBarButton?
    init(_ button: NSStatusBarButton? = nil) { self.button = button }
}

@MainActor @Suite struct StatusItemHaloTests {
    static let halo = Halo(glyph: .bottle, ink: .light, side: 24)

    @Test func breathingMovesOnlyOpacityBetweenItsBoundsOnASineCurve() throws {
        let layer = CALayer()
        HaloBreath.breathing.apply(to: layer)
        let breath = try #require(layer.animation(forKey: HaloBreath.key) as? CABasicAnimation)
        #expect(breath.keyPath == "opacity")
        #expect(breath.fromValue as? Float == 0.35 && breath.toValue as? Float == 1)
        #expect(breath.duration == 4.2 && breath.autoreverses && breath.repeatCount == .infinity)
        var point: [Float] = [0, 0]
        breath.timingFunction?.getControlPoint(at: 1, values: &point)
        #expect(point == [0.37, 0])
    }

    @Test func reduceMotionHoldsItStill() {
        let layer = CALayer()
        HaloBreath.breathing.apply(to: layer)
        HaloBreath(reduceMotion: true).apply(to: layer)
        #expect(layer.animation(forKey: HaloBreath.key) == nil)
        #expect(layer.opacity == 0.7)
    }

    @Test func aHaloAskedForBeforeTheButtonExistsReachesItWhenItDoes() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        let bar = Bar()
        let owner = StatusItemHalo(findButton: { bar.button }, reduceMotion: { false })
        owner.show(Self.halo)
        #expect(owner.layer.superlayer == nil)
        bar.button = button
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: nil)
        #expect(owner.layer.superlayer === button.layer)
        #expect(!owner.layer.isHidden && owner.layer.contents != nil)
        #expect(owner.layer.frame == CGRect(x: 3, y: -1, width: 24, height: 24))
        #expect(owner.layer.animation(forKey: HaloBreath.key) != nil)
    }

    @Test func aButtonThatResizesOrIsReplacedKeepsTheHaloCentredOnIt() {
        let bar = Bar(NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 22)))
        let owner = StatusItemHalo(findButton: { bar.button }, reduceMotion: { false })
        owner.show(Self.halo)
        // No window update follows SwiftUI's resize of the button; its own frame change has to be enough.
        bar.button?.frame.size.width = 22
        #expect(owner.layer.frame == CGRect(x: -1, y: -1, width: 24, height: 24))
        bar.button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: nil)
        #expect(owner.layer.superlayer === bar.button?.layer)
        #expect(owner.layer.frame == CGRect(x: 3, y: -1, width: 24, height: 24))
        #expect(owner.layer.animation(forKey: HaloBreath.key) != nil)
    }

    @Test func updatesThatChangeNothingLeaveTheBreathRunning() throws {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        let owner = StatusItemHalo(findButton: { button }, reduceMotion: { false })
        owner.show(Self.halo)
        let first = try #require(owner.layer.animation(forKey: HaloBreath.key))
        owner.show(Self.halo)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: nil)
        #expect(owner.layer.animation(forKey: HaloBreath.key) === first)
    }

    @Test func noHaloHidesTheLayer() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        let owner = StatusItemHalo(findButton: { button }, reduceMotion: { false })
        owner.show(Self.halo)
        owner.show(nil)
        #expect(owner.layer.isHidden && owner.layer.contents == nil)
    }
}
