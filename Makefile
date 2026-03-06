APP_NAME = Blackbox
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
SPARKLE_PATH = $(shell find .build/artifacts -name "Sparkle.framework" -path "*/macos-arm64_x86_64/*" | head -1)
SIGN_ID = $(shell security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
ENTITLEMENTS = <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>

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
	@if [ -n "$(SIGN_ID)" ]; then \
		echo "Signing with: $(SIGN_ID)"; \
		find "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework" -type f \( -name "*.xpc" -o -name "Autoupdate" -o -name "Updater" -o -name "Downloader" -o -name "Installer" -o -name "Sparkle" \) | while read f; do \
			codesign --force --options runtime --sign "$(SIGN_ID)" --timestamp "$$f"; \
		done; \
		codesign --force --options runtime --sign "$(SIGN_ID)" --timestamp "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
		codesign --force --options runtime --sign "$(SIGN_ID)" --identifier com.tenequm.Blackbox --timestamp --entitlements /dev/stdin "$(APP_BUNDLE)" <<< '$(ENTITLEMENTS)'; \
	else \
		echo "No Developer ID found, using ad-hoc signing"; \
		codesign --force --sign - --identifier com.tenequm.Blackbox --entitlements /dev/stdin "$(APP_BUNDLE)" <<< '$(ENTITLEMENTS)'; \
	fi

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
