APP  := OrangeDrink
DEST := platform=macOS,arch=arm64
XCB  := xcodebuild -scheme $(APP) -destination '$(DEST)' -derivedDataPath build/DerivedData

.PHONY: generate build test unplug-check cpu-check

generate:
	xcodegen generate --use-cache

build: generate
	$(call gated,build)

test: generate
	$(call gated,test)

# The ticket's step on a real Mac: unplug the adapter, wait a few seconds, plug it back in.
# The variable reaches the test host as UNPLUG_CHECK (xcodebuild strips TEST_RUNNER_) and
# enables the one test that needs a person at the cable.
unplug-check: export TEST_RUNNER_UNPLUG_CHECK = 1
unplug-check: test

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
