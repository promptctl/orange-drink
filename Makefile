APP  := OrangeDrink
DEST := platform=macOS,arch=arm64
XCB  := xcodebuild -scheme $(APP) -destination '$(DEST)'

.PHONY: generate build test

generate:
	xcodegen generate --use-cache

build: generate
	$(call gated,build)

test: generate
	$(call gated,test)

# [LAW:verifiable-goals] "Zero warnings" is read from the result bundle, which counts every
# build issue. Grepping xcodebuild's output would count tool chatter (appintentsmetadataprocessor
# prints a "warning:" line whenever no target links AppIntents) and is not the compiler's map.
define gated
rm -rf build/$(1).xcresult
$(XCB) -resultBundlePath build/$(1).xcresult $(1)
xcrun xcresulttool get build-results --path build/$(1).xcresult | python3 -c 'import json, sys; n = json.load(sys.stdin)["warningCount"]; print(f"build warnings: {n}"); sys.exit(n != 0)'
endef
