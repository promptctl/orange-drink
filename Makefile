SHELL := /bin/bash
APP  := OrangeDrink
DEST := platform=macOS,arch=arm64
# [LAW:one-source-of-truth] Where builds land; every target reads the products from here, and
# scripts/dmg points it at a directory of its own so a release is a clean build.
DERIVED_DATA := build/DerivedData
PRODUCTS := $(DERIVED_DATA)/Build/Products
RELEASE_APP := $(PRODUCTS)/Release/$(APP).app
# [LAW:one-source-of-truth] Which copy of the app a build is, for the helper's label (project.yml's
# HELPER_LABEL): one per derived-data directory, so no two checkouts share a helper. scripts/dmg passes
# it empty, which gives the app users install the one fixed label.
HELPER_COPY ?= .$(shell printf %s '$(abspath $(DERIVED_DATA))' | shasum | cut -c1-8)
XCB  := xcodebuild -scheme $(APP) -destination '$(DEST)' -derivedDataPath $(DERIVED_DATA) HELPER_COPY='$(HELPER_COPY)'

.PHONY: generate build release sparkle-tools test hardware-check-test release-test vm-check-test vm-test app-energy-check cpu-check ax-check helper-check release-helper-check update-check

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
	$(MAKE) hardware-check-test
	$(MAKE) release-test
	$(MAKE) vm-check-test

# The recorder behind the hardware checks, run against stand-ins for lit and xcrun: it needs no person and no device.
hardware-check-test:
	scripts/hardware-check-test.sh

# The release workflow's scripts, run against stand-ins for security, xcrun, base64 and spctl: no keychain or notary call.
release-test:
	scripts/release-test.sh

# The VM checks' common steps, run against a stand-in for tart: no VM boots.
vm-check-test:
	scripts/vm-check-test.sh

# The hosted tests in a VM with no window, because the test host is the app, which puts its status item in the menu bar.
# The warning gate runs here, and the VM only runs what was built. Prints the result bundle's counts and failures.
vm-test: generate
	$(call gated,build-for-testing)
	scripts/vm-test "$$(ls -t $(PRODUCTS)/*.xctestrun | head -n 1)"

# [LAW:one-type-per-behavior] The checks that need a real Mac are one recipe, and each is only data declared beside its
# target: its test (Suite/function()) and the source paths that test covers. scripts/hardware-check.swift runs the test
# alone and posts the result on the lit ticket the branch names; make hardware-status says which results still hold for
# HEAD.
# [LAW:verifiable-goals] A check is here only for what a real device or macOS service replies, and it observes every fact
# it asserts or records itself; a person only moves a cable or gives an approval macOS keeps for the user. Everything
# else is tested in `make test`. docs/testing.md says which layer tests what.
HARDWARE_CHECKS := unplug-check iphone-check devices-check position-check helper-repair-check
.PHONY: $(HARDWARE_CHECKS) hardware-status

$(HARDWARE_CHECKS): generate
	rm -rf build/$@.xcresult build/$@.record
	swift scripts/hardware-check.swift run $@ --test '$($@.test)' --bundle build/$@.xcresult --covers $($@.covers) \
	  -- $(XCB) -resultBundlePath build/$@.xcresult '-only-testing:$(APP)Tests/$($@.test)' test

# For the branch's ticket, each check's latest result: "stands" while the code it covered is unchanged at HEAD, with a
# failed result's failures beneath it, "stale" naming the paths that changed since, or "never run". A standing pass needs
# no one; a standing fail needs a change to the code, or to the setup its failures name, before it is worth a person's time.
hardware-status:
	swift scripts/hardware-check.swift status $(foreach check,$(HARDWARE_CHECKS),--check $(check) $($(check).covers))

# The ticket's step on a real Mac: unplug the adapter, wait a few seconds, plug it back in.
# The variable reaches the test host as UNPLUG_CHECK (xcodebuild strips TEST_RUNNER_) and
# enables the one test that needs a person at the cable.
unplug-check: export TEST_RUNNER_UNPLUG_CHECK = 1
unplug-check.test := BatteryLive/plugAndUnplug()
unplug-check.covers := Sources/OrangeDrink/Battery Tests/OrangeDrinkTests/BatteryLiveTests.swift Tests/OrangeDrinkTests/BatteryLog.swift

# The iPhone & iPad ticket's step on a real Mac: with one trusted iPhone or iPad cabled, switches its Wi-Fi sync off, then
# has the monitor switch it on and read the device over the cable, waits for the cable to be pulled, and reads it over Wi-Fi.
# project.yml is covered because it keeps the app unsandboxed, which its connection to usbmuxd's socket needs.
iphone-check: export TEST_RUNNER_IPHONE_CHECK = 1
iphone-check.test := IPhoneLive/switchesOnWifiSyncThenKeepsReadingOverWifiOnceTheCableIsPulled()
iphone-check.covers := Sources/OrangeDrink/IPhone Sources/OrangeDrink/Battery/Timekeeper.swift project.yml \
  Tests/OrangeDrinkTests/IPhoneLive.swift Tests/OrangeDrinkTests/BatteryLog.swift Tests/OrangeDrinkTests/PrintForTheRecord.swift

# The devices ticket's step on a real Mac: with paired devices connected, holds every device system_profiler lists
# with a level to the app's sweep. project.yml is covered for the Bluetooth usage description.
devices-check: export TEST_RUNNER_DEVICES_CHECK = 1
devices-check.test := DevicesLive/matchesSystemProfiler()
devices-check.covers := Sources/OrangeDrink/Devices Sources/OrangeDrink/Battery/PowerSources.swift Sources/OrangeDrink/Battery/Timekeeper.swift project.yml \
  Tests/OrangeDrinkTests/DevicesTests.swift Tests/OrangeDrinkTests/BatteryLog.swift Tests/OrangeDrinkTests/PrintForTheRecord.swift

# The pinned devices ticket on the real menu bar: puts three status items in it for a moment, reorders
# them, and checks the bar follows the list, including over a position left by a ⌘-drag.
position-check: export TEST_RUNNER_POSITION_CHECK = 1
position-check.test := PinnedPositionCheck/theBarFollowsTheListEvenOverASavedPosition()
position-check.covers := Sources/OrangeDrink/MenuBar/PinnedItems.swift Sources/OrangeDrink/Devices/PinnedOrder.swift \
  Sources/OrangeDrink/Devices/Device.swift Sources/OrangeDrink/Devices/DeviceRanking.swift Tests/OrangeDrinkTests/PinnedOrderTests.swift

# The privileged helper's check on a real Mac, with OrangeDrink approved under System Settings › General ›
# Login Items & Extensions › Allow in the Background: the helper, running as root from this build, accepts
# the app and refuses other code, including a copy re-signed with the app's identifier. Same TEST_RUNNER_ shape.
helper-check: export TEST_RUNNER_HELPER_CHECK = 1
helper-check: test

# The helper's repair on a real Mac, approved as above: wedges this build's job by re-signing its helper for a moment,
# then holds the app's own reconcile to a helper that answers as root, through background task management's refusal of
# a register straight after an unregister. Alone, because it changes the helper file HelperBuildTests reads.
helper-repair-check: export TEST_RUNNER_HELPER_REPAIR_CHECK = 1
helper-repair-check.test := HelperRepairLive/aJobLaunchdWillNotRunIsRepaired()
helper-repair-check.covers := Sources/OrangeDrink/Helper Sources/HelperInterface Sources/OrangeDrinkHelper project.yml \
  Tests/OrangeDrinkTests/HelperLive.swift Tests/OrangeDrinkTests/BatteryLog.swift

# The signed Release build's helper on a real Mac, approved as above: answers a charge-limit call at launch, and again
# at the launch after a crash, and leaves no job once the app quits; and a copy running other code replaces the helper
# a crash left running.
release-helper-check: release
	swift scripts/release-helper-check.swift "$(RELEASE_APP)"

# An update in place on real macOS, in a VM with no window: installs a build from its disk image there, then has its
# updater find nothing newer on a local feed, and install a higher version from it. scripts/update-check reads each result
# off the installed app. The newer build is the tree with only its version raised, built and notarized as a release is.
# It needs Tart, the VM image scripts/update-check names, and the signing key in this Mac's keychain. The tree is generated
# uncached: the generated files are under build/, which is not copied, and `--use-cache` would call a second run's copy
# unchanged and leave them missing.
update-check: generate
	@set -e; out='$(CURDIR)/build/update-check'; rm -rf "$$out"; mkdir -p "$$out/tree"; \
	rsync -a --exclude .git --exclude .claude --exclude build ./ "$$out/tree/"; \
	version=$$(scripts/version); newer=$${version%.*}.$$(( $${version##*.} + 1 )); \
	sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$$newer\"/" "$$out/tree/project.yml"; \
	xcodegen generate --spec "$$out/tree/project.yml"; \
	older_dmg=$$(scripts/dmg "$$out/older"); newer_dmg=$$("$$out/tree/scripts/dmg" "$$out/newer"); \
	xcodebuild -scheme $(APP)UITests -destination '$(DEST)' -derivedDataPath "$$out/ui" build-for-testing; \
	scripts/update-check "$$older_dmg" "$$newer_dmg" "$$out"/ui/Build/Products/*.xctestrun

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
cpu-check: release
	swift scripts/cpu-check.swift "$(RELEASE_APP)/Contents/MacOS/$(APP)"

# The Release app. The last line printed is the app's path, so scripts/dmg spells neither the
# configuration's directory nor the app's name.
release: generate
	$(call gated,build,-configuration Release)
	@echo $(RELEASE_APP)

# Sparkle's release tools, from the package project.yml pins. The last line printed is their directory, so no script
# spells the artifact's path or version.
sparkle-tools: generate
	$(XCB) -resolvePackageDependencies >&2
	@echo $(abspath $(DERIVED_DATA))/SourcePackages/artifacts/sparkle/Sparkle/bin

# [LAW:verifiable-goals] "Zero warnings" is read from the result bundle, which counts every
# build issue. Grepping xcodebuild's output would count tool chatter (appintentsmetadataprocessor
# prints a "warning:" line whenever no target links AppIntents) and is not the compiler's map.
define gated
rm -rf $(DERIVED_DATA)/$(1).xcresult
$(XCB) -resultBundlePath $(DERIVED_DATA)/$(1).xcresult $(1) $(2)
xcrun xcresulttool get build-results --path $(DERIVED_DATA)/$(1).xcresult | python3 -c 'import json, sys; n = json.load(sys.stdin)["warningCount"]; print(f"build warnings: {n}"); sys.exit(n != 0)'
endef

# The shared settings components through the accessibility tree of the running app's component
# gallery (a Debug-only window). Outside `test` because only a client of the running app sees
# SwiftUI's tree; the invoking process must be trusted for Accessibility.
ax-check: generate
	$(call gated,build)
	@set -e; app=$(PRODUCTS)/Debug/$(APP).app; \
	"$$app/Contents/MacOS/$(APP)" -ComponentGallery & pid=$$!; \
	status=0; swift scripts/ax-check.swift $$pid || status=$$?; \
	kill $$pid; exit $$status
