APP  := OrangeDrink
DEST := platform=macOS,arch=arm64

.PHONY: generate build test

generate:
	xcodegen generate --use-cache

build: generate
	xcodebuild -scheme $(APP) -destination '$(DEST)' build

test: generate
	xcodebuild -scheme $(APP) -destination '$(DEST)' test
