APP_NAME = Blackbox
# Info.plist is the single source of truth for the version, so release-please
# only has to update one file and the two can no longer drift apart.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
DMG_NAME = $(APP_NAME)-$(VERSION).dmg
SPARKLE_PATH = $(shell find .build/artifacts -name "Sparkle.framework" -path "*/macos-arm64_x86_64/*" | head -1)
SMOKE_LOCK = /tmp/blackbox-smoke.lock
SIGN_ID = $(shell security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
ENTITLEMENTS = <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>

.PHONY: build bundle install run clean format format-check test test-unit check dmg release smoke-install smoke-test smoke

build:
	swift build -c release

bundle: build
	@[ -d "$(APP_BUNDLE)" ] && chmod -R u+rw "$(APP_BUNDLE)" || true
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp .build/release/$(APP_NAME) "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp .build/release/BlackboxWatchdog "$(APP_BUNDLE)/Contents/MacOS/BlackboxWatchdog"
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
		codesign --force --options runtime --sign "$(SIGN_ID)" --timestamp "$(APP_BUNDLE)/Contents/MacOS/BlackboxWatchdog"; \
		codesign --force --options runtime --sign "$(SIGN_ID)" --identifier com.tenequm.Blackbox --timestamp --entitlements /dev/stdin "$(APP_BUNDLE)" <<< '$(ENTITLEMENTS)'; \
	else \
		echo "No Developer ID found, using ad-hoc signing"; \
		codesign --force --sign - "$(APP_BUNDLE)/Contents/MacOS/BlackboxWatchdog"; \
		codesign --force --sign - --identifier com.tenequm.Blackbox --entitlements /dev/stdin "$(APP_BUNDLE)" <<< '$(ENTITLEMENTS)'; \
	fi

install: bundle
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	chmod -R u+rw "/Applications/$(APP_NAME).app"
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
	@set -e; \
	if [ -n "$$APPLE_ASC_KEY_ID" ]; then \
	  auth="--key $$APPLE_ASC_KEY_PATH --key-id $$APPLE_ASC_KEY_ID --issuer $$APPLE_ASC_ISSUER_ID"; \
	else \
	  auth="--keychain-profile blackbox"; \
	fi; \
	xcrun notarytool submit "$(BUILD_DIR)/$(DMG_NAME)" $$auth --wait --output-format json > "$(BUILD_DIR)/notary.json"; \
	cat "$(BUILD_DIR)/notary.json"; \
	status=$$(/usr/bin/plutil -extract status raw -o - "$(BUILD_DIR)/notary.json"); \
	if [ "$$status" != "Accepted" ]; then \
	  echo "ERROR: notarization returned $$status"; \
	  xcrun notarytool log "$$(/usr/bin/plutil -extract id raw -o - "$(BUILD_DIR)/notary.json")" $$auth || true; \
	  exit 1; \
	fi
	xcrun stapler staple "$(BUILD_DIR)/$(DMG_NAME)"
	xcrun stapler validate "$(BUILD_DIR)/$(DMG_NAME)"
	@echo "Notarized: $(BUILD_DIR)/$(DMG_NAME)"

# One command, everywhere. The hardware suite needs a real .app bundle plus
# Screen Recording and microphone grants; CI seeds both (see ci.yml), so there
# is no reason for local and CI to run different sets. A machine without the
# grants fails with an actionable message rather than silently skipping.
#
# The lock lives here rather than on `smoke-test` because this is the target
# that takes the audio devices - `check`, `smoke` and `smoke-test` all reach the
# hardware through it and inherit the serialization. Two concurrent runs fight
# over the default input/output device and fail each other spuriously.
# `lockf -k` holds a kernel flock(2) for the life of the command, so a run
# killed with -9 leaves nothing stale. macOS has no flock(1), and shlock(1)
# refuses to reclaim a lock whose recorded PID is dead.
test: bundle
	@/usr/bin/lockf -kt 0 $(SMOKE_LOCK) true 2>/dev/null || \
	  echo "another Blackbox test run is active, waiting for it to finish..."
	@/usr/bin/lockf -k $(SMOKE_LOCK) env BLACKBOX_RUN_HARDWARE_SMOKE=1 \
	  BLACKBOX_SMOKE_APP_PATH="$(PWD)/$(APP_BUNDLE)" swift test --disable-xctest

# Hermetic subset for a fast inner loop: no bundle, no permissions, no devices,
# and deliberately no lock - serializing it would slow the fast path for nothing.
test-unit:
	swift test --disable-xctest

smoke-install: install

smoke-test: test

smoke: test


check: format build test
	@echo "All checks passed."

format:
	swift-format --recursive Sources/ Tests/ --in-place

# Lint-only: `format` rewrites in place, so it can never fail a CI run.
# Uses the toolchain-bundled formatter so CI needs no Homebrew install.
format-check:
	swift format lint --recursive Sources/ Tests/ --strict

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
