# Orange Drink

Orange Drink is a battery monitor for your Mac. It lives in the menu bar and tells you about your battery at the moments you care about, so a laptop doesn't die in the middle of a video call.

The battery indicator built into macOS warns you only at 10% and 5%, and those levels cannot be changed. On recent versions of macOS it also repeats the warning every minute. Orange Drink lets you pick the levels, and it warns you once per level.

## What it does

- **Alerts at your levels:** set as many charge alerts as you want, such as 20%, 10%, and 3%. Each one shows once, when the level is reached.
- **Battery health:** shows how much charge the battery still holds compared with when it was new, and how many charge cycles it has used.
- **Charge limit:** stops charging at a level you choose, which helps the battery last longer. It is off until you turn it on.
- **App energy:** shows which apps use the most battery right now, and over the past day, week, or month.
- **Other devices:** shows the battery levels of Bluetooth devices, Apple Watch, and an iPhone or iPad connected with a cable.
- **History:** charts your Mac's battery level and health over the past day, week, or two weeks.
- **Widgets:** puts battery levels on your desktop or in Notification Center.

By default, press ⌃⌥J from anywhere to open the Orange Drink panel.

## Getting it

There is no downloadable app yet. To build it from source, see [For developers](#for-developers).

## For developers

Build it on an Apple Silicon Mac running macOS 14 or later. You need Xcode and XcodeGen, which you can install with `brew install xcodegen`. Then run:

```sh
make generate
make build
```

The Xcode project is generated from `project.yml`, so change that file and never edit the project by hand. Run `make test` to run the unit tests.

Run `scripts/dmg build/dmg` to build the downloadable disk image in `build/dmg`. The script builds the Release app, signs it with the Developer ID certificate and the hardened runtime, notarizes it with Apple, and staples the ticket. It then packs the app into a disk image with a link to Applications, signs, notarizes, and staples the image too, and prints its path, such as `build/dmg/OrangeDrink-0.1.0.dmg`. Expect it to take several minutes, mostly waiting on Apple's notary service. Before the first run, your Mac needs the "Developer ID Application: Brandon Fryslie (6R988MUU27)" certificate and its private key in the login keychain, plus Apple's "Developer ID Certification Authority" G2 intermediate certificate. Without the intermediate, `security find-identity -v -p codesigning` lists no valid identity. Store the notary credentials once with `xcrun notarytool store-credentials orange-drink-notary`.

Some checks need a real Mac and a person at the keyboard. Each one has a make target: `make unplug-check`, `make devices-check`, `make pill-check`, and `make position-check`. `make ax-check` also needs your terminal trusted for Accessibility.

[PROJECT.md](PROJECT.md) describes every feature and the quality bar the app must meet. [design-docs/](design-docs/README.md) describes each settings screen.

The `master` branch is protected. Changes go in through a pull request, and every review conversation must be resolved before it merges.
