import AppKit
import Testing
@testable import OrangeDrink

/// Finder, the DMG, Login Items and notifications show the icon the built bundle names. The tests run
/// inside the built app, so its Info.plist and resources are the shipped ones. macOS reads the named icon
/// from the compiled asset catalog; actool's AppIcon.icns beside it is a small fallback for old readers.
@Suite struct AppIconTests {
    @Test func theAppNamesItsIconAndTheCatalogHasEverySizeMacOSAsksFor() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
        let icon = try #require(Bundle.main.image(forResource: "AppIcon"))
        let sides = Set(icon.representations.map(\.pixelsWide))
        #expect(sides.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]), "\(sides.sorted())")
    }
}
