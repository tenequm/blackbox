APP_NAME = Blackbox
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
SPARKLE_PATH = $(shell find .build/artifacts -name "Sparkle.framework" -path "*/macos-arm64_x86_64/*" | head -1)

.PHONY: build bundle install run clean format

build:
	swift build -c release

bundle: build
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp .build/release/$(APP_NAME) "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp Assets/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp -R "$(SPARKLE_PATH)" "$(APP_BUNDLE)/Contents/Frameworks/"
	codesign --force --sign "Blackbox Development" --identifier com.tenequm.Blackbox --entitlements /dev/stdin "$(APP_BUNDLE)" <<< '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>'

install: bundle
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	xattr -rc "/Applications/$(APP_NAME).app"

run: bundle
	open "$(APP_BUNDLE)"

format:
	swift-format --recursive Sources/ --in-place

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
