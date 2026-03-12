APP_NAME = Blackbox
VERSION = 0.4.3
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
DMG_NAME = $(APP_NAME)-$(VERSION).dmg
SPARKLE_PATH = $(shell find .build/artifacts -name "Sparkle.framework" -path "*/macos-arm64_x86_64/*" | head -1)
SIGN_ID = $(shell security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
ENTITLEMENTS = <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>

.PHONY: build bundle install run clean format test check dmg release

build:
	swift build -c release

bundle: build
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp .build/release/$(APP_NAME) "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp Assets/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@for bundle in .build/arm64-apple-macosx/release/*.bundle; do \
		[ -d "$$bundle" ] && cp -R "$$bundle" "$(APP_BUNDLE)/Contents/Resources/" && echo "Bundled: $$(basename $$bundle)"; \
	done
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

run:
	-killall $(APP_NAME) 2>/dev/null; while pgrep -x $(APP_NAME) >/dev/null 2>&1; do sleep 0.5; done
	$(MAKE) bundle
	open "$(APP_BUNDLE)"

dmg: bundle
	@command -v create-dmg >/dev/null 2>&1 || { echo "ERROR: create-dmg not found. Install via: brew install create-dmg"; exit 1; }
	rm -f "$(BUILD_DIR)/$(DMG_NAME)"
	create-dmg \
		--volname "$(APP_NAME)" \
		--window-pos 200 120 \
		--window-size 540 380 \
		--icon-size 128 \
		--icon "$(APP_NAME).app" 140 190 \
		--app-drop-link 400 190 \
		--no-internet-enable \
		"$(BUILD_DIR)/$(DMG_NAME)" \
		"$(APP_BUNDLE)"
	@echo "DMG created: $(BUILD_DIR)/$(DMG_NAME)"

release: dmg
	@if [ -z "$(SIGN_ID)" ]; then echo "ERROR: No Developer ID found. Cannot notarize an ad-hoc signed build."; exit 1; fi
	xcrun notarytool submit "$(BUILD_DIR)/$(DMG_NAME)" --keychain-profile "blackbox" --wait
	xcrun stapler staple "$(BUILD_DIR)/$(DMG_NAME)"
	@echo "Notarized: $(BUILD_DIR)/$(DMG_NAME)"

test:
	swift test

check: format build test
	@echo "All checks passed."

format:
	swift-format --recursive Sources/ Tests/ --in-place

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
