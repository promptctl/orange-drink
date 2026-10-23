APP  := OrangeDrink
DEST := platform=macOS,arch=arm64
XCB  := xcodebuild -scheme $(APP) -destination '$(DEST)' -derivedDataPath build/DerivedData

.PHONY: generate build test app-energy-check cpu-check ax-check

generate:
	xcodegen generate --use-cache

build: generate
	$(call gated,build)

# The unit tests, then the accessibility-tree check of the shared settings components: SwiftUI builds
# its tree only for a client of the running app, so that check is its own process (see ax-check).
# It fails loudly, never skips, when the invoking terminal is not trusted for Accessibility.
test: generate
	$(call gated,test)
	$(MAKE) ax-check

# [LAW:one-type-per-behavior] The checks that need a person at a cable or a screen are one recipe, and each is only
# data declared beside its target: its test (Suite/function()), the source paths that test covers, and the questions
# only the person can answer. scripts/hardware-check.swift runs the test alone, asks the questions once at the end, and
# posts the result on the lit ticket the branch names; make hardware-status says which results still hold for HEAD.
HARDWARE_CHECKS := unplug-check iphone-check devices-check pill-check position-check
.PHONY: $(HARDWARE_CHECKS) hardware-status

$(HARDWARE_CHECKS): generate
	rm -rf build/$@.xcresult
	swift scripts/hardware-check.swift run $@ --test '$($@.test)' --bundle build/$@.xcresult --covers $($@.covers) \
	  --ask $($@.ask) -- $(XCB) -resultBundlePath build/$@.xcresult '-only-testing:$(APP)Tests/$($@.test)' test

# For the branch's ticket, each check's latest result: "stands" while the code it covered is unchanged at HEAD,
# "stale" naming the paths that changed since, or "never run". A check is worth a person's time only when it is not standing.
hardware-status:
	swift scripts/hardware-check.swift status $(foreach check,$(HARDWARE_CHECKS),--check $(check) $($(check).covers))

# The ticket's step on a real Mac: unplug the adapter, wait a few seconds, plug it back in.
# The variable reaches the test host as UNPLUG_CHECK (xcodebuild strips TEST_RUNNER_) and
# enables the one test that needs a person at the cable.
unplug-check: export TEST_RUNNER_UNPLUG_CHECK = 1
unplug-check.test := BatteryLive/plugAndUnplug()
unplug-check.covers := Sources/OrangeDrink/Battery Tests/OrangeDrinkTests/BatteryLiveTests.swift Tests/OrangeDrinkTests/BatteryLog.swift

# The iPhone & iPad ticket's step on a real Mac: with one trusted iPhone cabled, switches its Wi-Fi sync off, then has the
# monitor switch it on and read the phone over the cable, waits for the cable to be pulled, and reads it over Wi-Fi.
# project.yml is covered for the Info.plist keys macOS's Local Network decision reads.
iphone-check: export TEST_RUNNER_IPHONE_CHECK = 1
iphone-check.test := IPhoneLive/switchesOnWifiSyncThenKeepsReadingOverWifiOnceTheCableIsPulled()
iphone-check.covers := Sources/OrangeDrink/IPhone Sources/OrangeDrink/Battery/Timekeeper.swift project.yml \
  Tests/OrangeDrinkTests/IPhoneLive.swift Tests/OrangeDrinkTests/BatteryLog.swift Tests/OrangeDrinkTests/PrintForTheRecord.swift
iphone-check.ask := 'Did macOS show a Local Network prompt? (y/n)' \
  'Did the app appear under System Settings > Privacy & Security > Local Network? (y/n)'

# The devices ticket's step on a real Mac: with paired devices connected, prints each one's name,
# type, and level to compare with Control Center. project.yml is covered for the Bluetooth usage description.
devices-check: export TEST_RUNNER_DEVICES_CHECK = 1
devices-check.test := DevicesLive/matchesSystemProfiler()
devices-check.covers := Sources/OrangeDrink/Devices project.yml Tests/OrangeDrinkTests/DevicesTests.swift \
  Tests/OrangeDrinkTests/PrintForTheRecord.swift

# The alert pill: put an app full screen, then click the × of the pill that appears
# at the centre of the screen and again at the top, then once more at the centre with the screen glow.
pill-check: export TEST_RUNNER_PILL_CHECK = 1
pill-check.test := PillTests/pillsShowOverAFullScreenApp()
pill-check.covers := Sources/OrangeDrink/Alerts Sources/OrangeDrink/Settings/AppLanguage.swift \
  Sources/OrangeDrink/Battery/BatteryReading.swift Tests/OrangeDrinkTests/PillTests.swift

# The pinned devices ticket on the real menu bar: puts three status items in it for a moment, reorders
# them, and checks the bar follows the list, including over a position left by a ⌘-drag.
position-check: export TEST_RUNNER_POSITION_CHECK = 1
position-check.test := PinnedPositionCheck/theBarFollowsTheListEvenOverASavedPosition()
position-check.covers := Sources/OrangeDrink/MenuBar/PinnedItems.swift Sources/OrangeDrink/Devices/PinnedOrder.swift \
  Tests/OrangeDrinkTests/PinnedOrderTests.swift

# The app energy ticket's step on a real Mac: starts `yes > /dev/null` in Terminal, samples app energy for a minute,
# and asserts Terminal holds the most stored energy, as it leads Activity Monitor's Energy tab on an otherwise idle
# Mac (another busy app, such as a terminal hosting builds and agents, outranks it there too). Same TEST_RUNNER_ shape.
app-energy-check: export TEST_RUNNER_APP_ENERGY_CHECK = 1
# The window is kept quiet: the app and tests are built first, since a compiler running under the invoking terminal
# would out-draw the `yes` in Terminal, and only the live test runs while it samples.
app-energy-check: generate
	$(XCB) build-for-testing
	@set -e; \
	started=$$(osascript -e 'tell application "Terminal" to set started to do script "yes > /dev/null"' \
	  -e 'tell application "Terminal" to return ((id of (first window whose tabs contains started)) as text) & " " & (tty of started)'); \
	window=$${started%% *}; tty=$${started##*/dev/}; \
	status=0; $(XCB) -only-testing:OrangeDrinkTests/AppEnergyLive test-without-building || status=$$?; \
	yes_pids=$$(ps -t "$$tty" -o pid=,comm= | awk '$$2 == "yes" { print $$1 }'); [ -z "$$yes_pids" ] || kill $$yes_pids; \
	osascript -e "tell application \"Terminal\" to close (first window whose id is $$window) saving no"; \
	exit $$status

# [LAW:verifiable-goals] PROJECT.md's 0.1% steady-state CPU bar, measured on the Release build
# launched as a user runs it. Prints the percent and the power state; fails over the bar.
cpu-check: generate
	$(call gated,build,-configuration Release)
	swift scripts/cpu-check.swift build/DerivedData/Build/Products/Release/$(APP).app/Contents/MacOS/$(APP)

# [LAW:verifiable-goals] "Zero warnings" is read from the result bundle, which counts every
# build issue. Grepping xcodebuild's output would count tool chatter (appintentsmetadataprocessor
# prints a "warning:" line whenever no target links AppIntents) and is not the compiler's map.
define gated
rm -rf build/$(1).xcresult
$(XCB) -resultBundlePath build/$(1).xcresult $(1) $(2)
xcrun xcresulttool get build-results --path build/$(1).xcresult | python3 -c 'import json, sys; n = json.load(sys.stdin)["warningCount"]; print(f"build warnings: {n}"); sys.exit(n != 0)'
endef

# The shared settings components through the accessibility tree of the running app's component
# gallery (a Debug-only window). Outside `test` because only a client of the running app sees
# SwiftUI's tree; the invoking process must be trusted for Accessibility.
ax-check: generate
	$(call gated,build)
	@set -e; app=build/DerivedData/Build/Products/Debug/$(APP).app; \
	"$$app/Contents/MacOS/$(APP)" -ComponentGallery & pid=$$!; \
	status=0; swift scripts/ax-check.swift $$pid || status=$$?; \
	kill $$pid; exit $$status
