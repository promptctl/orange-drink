# Testing

Every behavior is tested at the lowest layer that owns it, in `make test`, with no screen, no device, and no person. A live check on a real Mac is the last layer. It is only for the one fact that nothing below it can reach: what a real device or macOS service actually replies. Running the app and watching it is not a test.

Before inventing a way to test something, look up how others test it. Search (Firecrawl or the web) for the standard technique: "how do people test X on macOS" usually has an answer, and it is usually not "run it live".

## The layers, lowest first

| What you are proving | How it is tested | Example in this repo |
|---|---|---|
| A decision: which alert fires, what a screen shows for some state, how a list is ordered | A unit test over values: feed the input, assert the output | `AlertEngine` tests, `DeviceList` tests |
| A parser of a device's or the OS's reply | A unit test over a reply recorded from real hardware, kept as a fixture | `IPhoneFixtures.swift`: lockdown replies captured from iPhones and iPads |
| Code that talks to the outside world | The outside is a stand-in behind the seam: a socketpair for usbmuxd, `ManualTimekeeper` for time, an injected closure for a sound | `IPhoneMonitorTests`, `AlertSounds(play:)` |
| What a view looks like | Render it with no window (`ImageRenderer`, or drawing into an `NSBitmapImageRep`) and assert on its pixels: which colour, how far it fills, what is clear | `MenuBarIconTests`, `PillTests.thePillDrawsItsBorderInItsAlertsColourAsFarAsItsLevel` |
| What a control does when pressed: a button's action, a toggle's binding | ViewInspector finds the control in the view value and calls its action, with no window (the SwiftUI accessibility tree exists only for a client of the running app) | `PillTests.pressingThePillsCloseButtonTakesItAndItsGlowDown` |
| What macOS does with a window: over full-screen apps, on every Space, click-through | Assert the properties macOS acts on (see below). How macOS honours them is Apple's behavior, not ours | `PillTests.thePillAndItsGlowAreWindowsMacOSShowsOverFullScreenApps` |
| What a real device or service replies, end to end | A live check, `make <check>`, on a real Mac (see below) | `make iphone-check`, `make devices-check` |

## Windows macOS places

Whether a window shows over a full-screen app, follows the user across Spaces, or lets clicks through is decided by how the window is built, and macOS honours it. So the test asserts how it is built: an `NSPanel` with `.nonactivatingPanel` that cannot become key, `collectionBehavior` containing `.canJoinAllSpaces` and `.fullScreenAuxiliary`, a level above full-screen windows (which sit at the main menu's level plus one), `ignoresMouseEvents` for click-through, and an app with no Dock icon (`LSUIElement`). Apple's developer support gives the same recipe (developer.apple.com/forums/thread/826308). Driving a real full-screen app to see whether a window appears tests the window server, takes seconds, and was shown not to catch a broken panel.

## Live checks

A live check exists only where the fact can't be recorded once and replayed: what a real iPhone, a real Bluetooth device, or a real power adapter reports right now. The live checks are the `HARDWARE_CHECKS` in the Makefile. Each one runs on a branch named after its ticket and posts its record there.

A live check observes every fact it asserts or records itself. It never asks a person what a device or macOS shows:

- What a device shows on its own screen is what the app reads from it. Settings > Battery Health's maximum capacity and cycle count are in the lockdown reading.
- A Bluetooth device's level is in `system_profiler SPBluetoothDataType` and in power management's accessory list, `pmset -g accps`.
- Whether macOS gated something is whether the read that needed it succeeded.
- Everything else is in `ioreg`, `pmset`, the unified log (`log show`), the window list, or the accessibility tree.

A person does only what no process can: move a cable or an adapter when the check prints that it's time, or give an approval macOS reserves for the user. The recorder (`scripts/hardware-check.swift`) reads nothing from the person, and it refuses an `--ask` flag.

## Tests that show UI

A test that puts anything on the screen never runs on a Mac someone is using. It appears in front of them, they close it, and its failure then says nothing about the app. A test that has to drive the real UI is an XCUITest, the framework Apple built for it, and it runs in a [Tart](https://tart.run) VM with no window, as `make update-check` does. Its clicks land where a person's would, so it also finds what a press through the accessibility API misses, such as a button another window covers. `make test`'s `ax-check` and `make position-check` still break this rule; orange-tests-xu4.mzr moves them.

## Writing a ticket's "Done when"

Name the test at the layer above that proves the outcome: "`make test` passes a test that …". Add a live check only for a real device's or service's reply, and say which values it reads and what they're compared with. Never write "a person sees", "matches what the phone shows", "matches Control Center", or "on a real Mac, X appears on screen". Those are a test at a lower layer, or a value the check reads itself.
