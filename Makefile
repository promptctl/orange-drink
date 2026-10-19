APP  := OrangeDrink
DEST := platform=macOS,arch=arm64
XCB  := xcodebuild -scheme $(APP) -destination '$(DEST)'

.PHONY: generate build test unplug-check

generate:
	xcodegen generate --use-cache

build: generate
	$(call gated,build)

# [LAW:one-source-of-truth] The one test that needs a person at the cable. `test` skips it and
# `unplug-check` runs it alone; the scheme's SkippedTests is not honoured for Swift Testing by
# xcodebuild, and the identifier must carry the "()" or neither flag matches.
UNPLUG_TEST := 'OrangeDrinkTests/BatteryLive/plugAndUnplug()'

test: generate
	$(call gated,test -skip-testing:$(UNPLUG_TEST))

# The ticket's step on a real Mac: unplug the adapter, wait a few seconds, plug it back in.
unplug-check: generate
	$(XCB) test -only-testing:$(UNPLUG_TEST)

# [LAW:verifiable-goals] "Zero warnings" is read from the result bundle, which counts every
# build issue. Grepping xcodebuild's output would count tool chatter (appintentsmetadataprocessor
# prints a "warning:" line whenever no target links AppIntents) and is not the compiler's map.
define gated
rm -rf build/$(firstword $(1)).xcresult
$(XCB) -resultBundlePath build/$(firstword $(1)).xcresult $(1)
xcrun xcresulttool get build-results --path build/$(firstword $(1)).xcresult | python3 -c 'import json, sys; n = json.load(sys.stdin)["warningCount"]; print(f"build warnings: {n}"); sys.exit(n != 0)'
endef
