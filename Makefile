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
# Extra build settings for every xcodebuild, empty on a developer's Mac. A hosted CI runner holds no Developer ID
# certificate, so the test workflow passes the ad-hoc identity here.
XCB_SETTINGS ?=
XCB  := xcodebuild -scheme $(APP) -destination '$(DEST)' -derivedDataPath $(DERIVED_DATA) HELPER_COPY='$(HELPER_COPY)' $(XCB_SETTINGS)

.PHONY: generate build release sparkle-tools test ci-test script-tests hardware-check-test release-test vm-check-test place-widgets-test ui-test app-energy-check cpu-check layout-events-count layout-events-count-test helper-check release-helper-check update-check login-item-check first-launch-check battery-notification-check widget-click-check iphone-list iphone-capture iphone-devices-test notification-fixtures notification-fixtures-test

generate:
	xcodegen generate --use-cache

build: generate
	$(call gated,build)

# The unit tests, then the UI tests in a VM (see ui-test), then the scripts' tests. Nothing shows on this Mac's screen.
test: generate
	$(call gated,test)
	$(MAKE) ui-test
	$(MAKE) script-tests

# `test` for a hosted runner, which the test workflow runs and the release refuses a commit without
# (scripts/release-tested). It leaves out ui-test, whose Tart VM a hosted runner cannot boot, and the
# tests that ask this Mac a question a hosted runner's VM cannot answer: BatteryLive reads the Mac's battery, which the VM
# has none of; the two HelperBuildTests read the Developer ID team off the helper's signature, which the ad-hoc build there
# lacks; and pmsetRunsToItsEndOrItsDeadline reads pmset's power mode, which the VM does not list. Only `test` runs them.
CI_UNANSWERABLE := BatteryLive HelperBuildTests/helperIsSignedToServeOnlyThisApp() HelperBuildTests/releaseHelpersRefuseADebuggableApp() \
  PowerModeKeyTests/pmsetRunsToItsEndOrItsDeadline()
ci-test: generate
	$(call gated,test,$(foreach t,$(CI_UNANSWERABLE),'-skip-testing:$(APP)Tests/$(t)'))
	$(MAKE) script-tests

# The tests of the scripts, which need no person and no device; `test` and `ci-test` both end with them.
script-tests:
	$(MAKE) hardware-check-test
	$(MAKE) release-test
	$(MAKE) vm-check-test
	$(MAKE) place-widgets-test
	$(MAKE) layout-events-count-test
	$(MAKE) iphone-devices-test
	$(MAKE) notification-fixtures-test

# The recorder behind the hardware checks, run against stand-ins for lit and xcrun: it needs no person and no device.
hardware-check-test:
	scripts/hardware-check-test.sh

# The release workflow's scripts, run against stand-ins for security, xcrun, base64 and spctl: no keychain or notary call.
release-test:
	scripts/release-test.sh

# The VM checks' common steps, run against a stand-in for tart: no VM boots.
vm-check-test:
	scripts/vm-check-test.sh

# The store scripts/place-widgets writes, decoded and held against what macOS wrote and what the widgets declare: no VM.
place-widgets-test:
	scripts/place-widgets-test.py

# The UI tests that open the app's windows, in a VM with no window: the Debug build's component gallery, through the
# accessibility tree SwiftUI builds only for a client of the running app, and what the app wires up as it launches.
# It needs Tart and the VM image scripts/vm-check-lib names.
ui-test: build
	$(call gated,build-for-testing,,$(subst -scheme $(APP) ,-scheme $(APP)UITests ,$(XCB)))
	scripts/ui-test "$$(ls -t $(PRODUCTS)/$(APP)UITests*.xctestrun | head -n 1)"

# [LAW:one-type-per-behavior] The checks that need a real Mac are one list, and each is only data declared beside its
# target: the source paths it covers, and either its test (Suite/function()) or a recipe whose last command is a script.
# scripts/hardware-check.swift runs the check and posts the result on the lit ticket the branch names; make
# hardware-status says which results still hold for HEAD. A test's outcome is read from its result bundle. A script runs
# through $(record) and its exit status is the result (0 passed, anything else failed, with the reason it printed): what it
# builds first stays outside the record, so a build or a notarization that fails is not a failed check.
# [LAW:verifiable-goals] A check is here only for what a real device or macOS service replies, and it observes every fact
# it asserts or records itself; a person only moves a cable or gives an approval macOS keeps for the user. Everything
# else is tested in `make test`. docs/testing.md says which layer tests what.
HARDWARE_CHECKS := unplug-check iphone-check iphone-identity-check devices-check position-check helper-repair-check \
  release-helper-check update-check login-item-check battery-notification-check notification-fixtures-check
.PHONY: $(HARDWARE_CHECKS) hardware-status
record = swift scripts/hardware-check.swift run $@ --covers $($@.covers) --

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
iphone-check.covers := Sources/OrangeDrink/IPhone Sources/OrangeDrink/Blocking.swift Sources/OrangeDrink/Battery/Timekeeper.swift project.yml \
  Tests/OrangeDrinkTests/IPhoneLive.swift Tests/OrangeDrinkTests/BatteryLog.swift Tests/OrangeDrinkTests/PrintForTheRecord.swift

# The device sources ticket's step on a real Mac: with an iPhone, iPad or Vision Pro this Mac trusts reachable, cabled or on
# Wi-Fi, reads each one's name, model and Bluetooth address from lockdown and holds them to the Mac's own record of the device
# (system_profiler's paired devices, com.apple.iPod's Product Type). No cable and no person. project.yml is covered because it
# keeps the app unsandboxed, which its connection to usbmuxd's socket needs.
iphone-identity-check: export TEST_RUNNER_IPHONE_IDENTITY_CHECK = 1
iphone-identity-check.test := IPhoneIdentityLive/identityMatchesTheMacsOwnRecord()
iphone-identity-check.covers := Sources/OrangeDrink/IPhone Sources/OrangeDrink/Devices/BluetoothAddress.swift project.yml \
  Tests/OrangeDrinkTests/IPhoneIdentityLive.swift Tests/OrangeDrinkTests/PrintForTheRecord.swift

# The devices ticket's step on a real Mac: with paired devices connected, holds every device system_profiler lists
# with a level to the app's sweep. project.yml is covered for the Bluetooth usage description.
devices-check: export TEST_RUNNER_DEVICES_CHECK = 1
devices-check.test := DevicesLive/matchesSystemProfiler()
devices-check.covers := Sources/OrangeDrink/Devices Sources/OrangeDrink/Battery/PowerSources.swift Sources/OrangeDrink/Battery/Timekeeper.swift project.yml \
  Tests/OrangeDrinkTests/DevicesTests.swift Tests/OrangeDrinkTests/BatteryLog.swift Tests/OrangeDrinkTests/PrintForTheRecord.swift

# The pinned devices ticket on a real menu bar, a VM's, because it puts three status items in it: reorders them, and
# checks the bar follows the list, including over a position left by a ⌘-drag.
position-check.covers := Sources/OrangeDrink/MenuBar/PinnedItems.swift Sources/OrangeDrink/Devices/PinnedOrder.swift \
  Sources/OrangeDrink/Devices/Device.swift Sources/OrangeDrink/Devices/DeviceRanking.swift Tests/OrangeDrinkTests/PinnedOrderTests.swift \
  Sources/OrangeDrink/Main.swift scripts/vm-test scripts/vm-check-lib
position-check: generate
	$(call gated,build-for-testing)
	$(record) scripts/vm-test "$$(ls -t $(PRODUCTS)/$(APP)_*.xctestrun | head -n 1)" \
	  'PinnedPositionCheck/theBarFollowsTheListEvenOverASavedPosition()' TEST_RUNNER_POSITION_CHECK=1

# The privileged helper's check on a real Mac, with OrangeDrink approved under System Settings › General ›
# Login Items & Extensions › Allow in the Background: the helper, running as root from this build, accepts
# the app and refuses other code, including a copy re-signed with the app's identifier. Same TEST_RUNNER_ shape.
helper-check: export TEST_RUNNER_HELPER_CHECK = 1
helper-check: generate
	$(call gated,test)

# The helper's repair on a real Mac, approved as above: wedges this build's job by re-signing its helper for a moment,
# then holds the app's own reconcile to a helper that answers as root, through background task management's refusal of
# a register straight after an unregister. Alone, because it changes the helper file HelperBuildTests reads.
helper-repair-check: export TEST_RUNNER_HELPER_REPAIR_CHECK = 1
helper-repair-check.test := HelperRepairLive/aJobLaunchdWillNotRunIsRepaired()
helper-repair-check.covers := Sources/OrangeDrink/Helper Sources/HelperInterface Sources/OrangeDrinkHelper project.yml \
  Tests/OrangeDrinkTests/HelperLive.swift Tests/OrangeDrinkTests/BatteryLog.swift

# Every check that declares a `.test` runs it through xcodebuild. The rule sits after the declarations because make
# expands a rule's targets as it reads the rule.
$(foreach check,$(HARDWARE_CHECKS),$(if $($(check).test),$(check))): generate
	rm -rf build/$@.xcresult build/$@.record
	swift scripts/hardware-check.swift run $@ --test '$($@.test)' --bundle build/$@.xcresult --covers $($@.covers) \
	  -- $(XCB) -resultBundlePath build/$@.xcresult '-only-testing:$(APP)Tests/$($@.test)' test

# The signed Release build's helper on a real Mac, approved as above: answers a charge-limit call at launch, and again
# at the launch after a crash, and leaves no job once the app quits; and a copy running other code replaces the helper
# a crash left running.
release-helper-check.covers := Sources/OrangeDrink/Helper Sources/HelperInterface Sources/OrangeDrinkHelper project.yml \
  scripts/release-helper-check.swift
release-helper-check: release
	$(record) swift scripts/release-helper-check.swift "$(RELEASE_APP)"

# An update in place on real macOS, in a VM with no window: installs a build from its disk image there, then has its
# updater find nothing newer on a local feed, and install a higher version from it. scripts/update-check reads each result
# off the installed app, and the helper's handshake answering from the updated copy, after allowing the helper as a person
# does. The newer build is the tree with only its version raised, built and notarized as a release is.
# It needs Tart, the VM image scripts/vm-check-lib names, and the signing key in this Mac's keychain. The tree is generated
# uncached: the generated files are under build/, which is not copied, and `--use-cache` would call a second run's copy
# unchanged and leave them missing.
update-check.covers := Sources/OrangeDrink/Updates Sources/OrangeDrink/Helper Sources/HelperInterface Sources/OrangeDrinkHelper \
  Sources/OrangeDrink/OrangeDrinkApp.swift Sources/OrangeDrink/Panel/PanelView.swift project.yml Tests/OrangeDrinkUITests \
  scripts/update-check scripts/appcast scripts/dmg scripts/vm-check-lib
update-check: generate
	@set -e; out='$(CURDIR)/build/update-check'; rm -rf "$$out"; mkdir -p "$$out/tree"; \
	rsync -a --exclude .git --exclude .claude --exclude build ./ "$$out/tree/"; \
	version=$$(scripts/version); newer=$${version%.*}.$$(( $${version##*.} + 1 )); \
	sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$$newer\"/" "$$out/tree/project.yml"; \
	xcodegen generate --spec "$$out/tree/project.yml"; \
	older_dmg=$$(scripts/dmg "$$out/older"); newer_dmg=$$("$$out/tree/scripts/dmg" "$$out/newer"); \
	xcodebuild -scheme $(APP)UITests -destination '$(DEST)' -derivedDataPath "$$out/ui" build-for-testing; \
	$(record) scripts/update-check "$$older_dmg" "$$newer_dmg" "$$out"/ui/Build/Products/*.xctestrun

# Launch at login on real macOS, in a VM with no window, because registering posts a notification on the Mac it happens
# on: installs a build from its disk image there, allows it in System Settings as a person does, presses the General
# screen's switch off and on, and reads what SMAppService.mainApp.status said after each off the app's log. It needs what
# update-check needs.
login-item-check.covers := Sources/OrangeDrink/Settings/LaunchAtLogin.swift Sources/OrangeDrink/Blocking.swift Tests/OrangeDrinkUITests \
  scripts/login-item-check scripts/dmg scripts/vm-check-lib
login-item-check: generate
	@set -e; out='$(CURDIR)/build/login-item-check'; rm -rf "$$out"; mkdir -p "$$out"; \
	dmg=$$(scripts/dmg "$$out/dmg"); \
	xcodebuild -scheme $(APP)UITests -destination '$(DEST)' -derivedDataPath "$$out/ui" build-for-testing; \
	$(record) scripts/login-item-check "$$dmg" "$$out"/ui/Build/Products/*.xctestrun

# A new install's first launch on real macOS, in a VM with no window, because only a new install meets the Bluetooth
# prompt: scripts/first-launch-check presses the status item with the prompt open and reads what each answer did. The
# Release build is signed and needs no notarizing, because nothing in the VM quarantines it. It needs Tart and the VM
# image scripts/vm-check-lib names.
first-launch-check: release
	@set -e; out='$(CURDIR)/build/first-launch-check'; rm -rf "$$out"; mkdir -p "$$out"; \
	xcodebuild -scheme $(APP)UITests -destination '$(DEST)' -derivedDataPath "$$out/ui" build-for-testing; \
	scripts/first-launch-check "$(RELEASE_APP)" "$$out"/ui/Build/Products/*.xctestrun

# Closing macOS's low battery notification on real macOS, in a VM of each macOS the finding proved, with no window, because
# only a real discharge raises the notification on a Mac with a battery. scripts/battery-notification-check reads each
# result from NotificationCenter's accessibility tree. It needs Tart and these images.
BATTERY_NOTIFICATION_IMAGES := orange-drink-xcode ghcr.io/cirruslabs/macos-sequoia-base:latest ghcr.io/cirruslabs/macos-sonoma-base:latest
battery-notification-check.covers := Sources/OrangeDrink/SystemNotifications Sources/OrangeDrink/Battery/BatteryMonitor.swift \
  Sources/OrangeDrink/Battery/IOKitBattery.swift scripts/notification-tree.swift scripts/fake-battery.swift scripts/vm-check-lib \
  scripts/notification-vm-lib scripts/battery-notification-check
battery-notification-check: release
	@$(record) bash -c 'set -e; for image; do scripts/battery-notification-check "$(RELEASE_APP)" "$$image"; done' _ $(BATTERY_NOTIFICATION_IMAGES)

# The notification fixtures (Tests/OrangeDrinkTests/NotificationFixtures.swift) against today's macOS, in a VM of each image with no
# window: scripts/notification-capture reads what NotificationCenter's accessibility tree shows for the low battery alert and for
# another app's notification with the same words, in seven languages, and scripts/notification-fixtures check names every reading
# that differs from the committed capture of that macOS. It needs Tart and these images.
notification-fixtures-check.covers := Tests/OrangeDrinkTests/NotificationFixtures.swift scripts/notification-captures \
  scripts/notification-capture scripts/notification-fixtures scripts/notification-tree.swift scripts/fake-battery.swift \
  scripts/notification-vm-lib scripts/vm-check-lib
# Shell for one raw capture per image, numbered in $$out, a directory removed when the shell exits; $(1) is the images.
notification-sweep = set -e; out=$$(mktemp -d); trap "rm -rf $$out" EXIT; n=0; \
  for image in $(1); do n=$$((n + 1)); scripts/notification-capture "$$image" > "$$out/$$n.tsv"; done
notification-fixtures-check:
	@$(record) bash -c '$(call notification-sweep,$(BATTERY_NOTIFICATION_IMAGES)); python3 -I scripts/notification-fixtures check "$$out"/*.tsv'

# Recaptures the notification fixtures after a new macOS: the same sweep as notification-fixtures-check over the images in IMAGES,
# which replaces those macOS versions' captures in scripts/notification-captures and regenerates NotificationFixtures.swift from
# every committed capture. A failed image leaves both as they were. `git diff` then shows the wording that changed. Nothing shows on
# the Mac running it.
IMAGES ?= $(BATTERY_NOTIFICATION_IMAGES)
notification-fixtures:
	@$(call notification-sweep,$(IMAGES)); \
	python3 -I scripts/notification-fixtures record "$$out"/*.tsv; \
	python3 -I scripts/notification-fixtures render > "$$out/NotificationFixtures.swift"; \
	mv "$$out/NotificationFixtures.swift" Tests/OrangeDrinkTests/NotificationFixtures.swift

# The fixtures' tool, held against the committed captures and the Swift rendered from them: no VM.
notification-fixtures-test:
	scripts/notification-fixtures-test.py

# A click on a placed widget on real macOS, in a VM with no window, because only a real click makes macOS deliver what it
# delivers: scripts/widget-click-check places all three widgets, clicks them, and reads the app's log and the window list.
# It needs Tart and these images.
WIDGET_CLICK_IMAGES := orange-drink-xcode ghcr.io/cirruslabs/macos-sequoia-base:latest ghcr.io/cirruslabs/macos-sonoma-base:latest
widget-click-check: release
	@set -e; for image in $(WIDGET_CLICK_IMAGES); do scripts/widget-click-check "$(RELEASE_APP)" "$$image"; done

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

# How often NotificationCenter posts AXLayoutChanged, the event a low battery warning's pass runs on: a read-only count over
# WINDOW_SECONDS (300), with the screen's lock state and NotificationCenter's windows read alongside. cpu-check runs at warning
# level none and cannot see it. The invoking process must be trusted for Accessibility.
layout-events-count: WINDOW_SECONDS ?= 300
layout-events-count:
	swift scripts/layout-events-count.swift $(WINDOW_SECONDS)

# The figures that run prints, held against recorded events: no Accessibility trust, no NotificationCenter.
layout-events-count-test:
	scripts/layout-events-count-test.sh

# The iPhones and iPads usbmuxd lists, cable and Wi-Fi: an empty list is a Mac with none attached, not an error.
iphone-list:
	python3 -I scripts/iphone-devices list

# Every listed device's IOPMPowerSource reply, one plist per listing, into DIR: the source of the fixtures in
# Tests/OrangeDrinkTests/IPhoneFixtures.swift. The files hold serial numbers, so DIR belongs outside the repo.
iphone-capture:
	@test -n "$(DIR)" || { echo "usage: make iphone-capture DIR=<directory outside the repo>" >&2; exit 2; }
	python3 -I scripts/iphone-devices capture "$(DIR)"

# Both subcommands against a stand-in for usbmuxd: no device, no pairing.
iphone-devices-test:
	python3 -I scripts/iphone-devices-test.py

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
# $(3), when given, is the xcodebuild command in place of $(XCB), such as another scheme's.
define gated
rm -rf $(DERIVED_DATA)/$(1).xcresult
$(or $(3),$(XCB)) -resultBundlePath $(DERIVED_DATA)/$(1).xcresult $(1) $(2)
xcrun xcresulttool get build-results --path $(DERIVED_DATA)/$(1).xcresult | python3 -c 'import json, sys; n = json.load(sys.stdin)["warningCount"]; print(f"build warnings: {n}"); sys.exit(n != 0)'
endef
