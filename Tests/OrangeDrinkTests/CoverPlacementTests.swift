import AppKit
import SwiftUI
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is that a pill shown over a full-screen alert leaves the
// cover's block readable, on any display a Mac drives, at any bubble size (design-docs/alerts.md).
@MainActor @Suite(.serialized) struct CoverPlacementTests {
    /// The block as the cover lays it out, with its focus binding held by a view as the cover's is.
    private struct Measured: View {
        let content: CoverContent
        @AccessibilityFocusState private var focused: Bool
        var body: some View { CoverBlock(content: content, dismissFocused: $focused, onDismiss: {}) }
    }

    /// A display's frame and the part of it left by the menu bar and Dock, from a small laptop to a 6K display.
    nonisolated static let displays: [ScreenArea] = [
        ScreenArea(frame: CGRect(x: 0, y: 0, width: 1024, height: 640), visibleFrame: CGRect(x: 0, y: 70, width: 1024, height: 545)),
        ScreenArea(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)),
        ScreenArea(frame: CGRect(x: -3008, y: 0, width: 3008, height: 1692), visibleFrame: CGRect(x: -3008, y: 80, width: 3008, height: 1587)),
    ]

    /// The block's fitting size, the same on every display.
    static let size = Result { NSHostingView(rootView: Measured(content: CoverContent(CoverTests.critical, reading: try PillTests.reading(2)))).fittingSize }

    /// The block's rectangle on a display, centred on the whole screen as the cover centres it.
    static func block(on display: ScreenArea) throws -> CGRect {
        let size = try size.get()
        return CGRect(x: display.frame.midX - size.width / 2, y: display.frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    @Test(arguments: displays, NotificationAppearance.BubbleSize.allCases)
    func aCentrePillOverTheCoverClearsItsBlock(display: ScreenArea, size: NotificationAppearance.BubbleSize) throws {
        let block = try Self.block(on: display)
        let over = PillPlacement.frame(PillContent.Position.center.over(cover: true), on: display.visibleFrame, scale: size.scale)
        let under = PillPlacement.frame(.center, on: display.visibleFrame, scale: size.scale)
        #expect(!over.intersects(block))
        // Where it sat before, it covered the headline: the check above can fail.
        #expect(under.intersects(block))
    }

    @Test func aTopPillStaysAtTheTopOverTheCover() {
        #expect(PillContent.Position.top.over(cover: true) == .top)
    }

    @Test func aCentrePillWithNoCoverStaysAtTheCentre() {
        #expect(PillContent.Position.center.over(cover: false) == .center)
    }
}
