# Blackbox

macOS menu bar app that auto-records call audio using ScreenCaptureKit. Detects calls via CoreAudio microphone activity monitoring.

## Project Structure

```
Package.swift              - SPM manifest, macOS 15+, Swift 6.2
Sources/
  BlackboxApp.swift        - @main App, MenuBarExtra, Window scenes, AppDelegate
  AudioMonitor.swift       - @Observable: mic activity detection, auto/manual recording lifecycle
  AudioRecorder.swift      - SCStream + AVAssetWriter, dual-track M4A
  MainWindowView.swift     - Main window: TabView with Recordings table + Settings
  SettingsView.swift       - Settings UI, defaults constants
  OnboardingView.swift     - First-launch onboarding: permissions walkthrough
  RecordingHUD.swift       - Floating NSPanel toast (top-right), recording start + save with click-to-reveal
  Log.swift                - OSLog + file logging, debug export
Info.plist                 - LSUIElement, NSMicrophoneUsageDescription
Makefile                   - build, bundle, dmg, release, install, run, format, clean
```

## Build & Run

```sh
make build      # swift build -c release
make bundle     # build + create .app bundle + codesign
make dmg        # bundle + create DMG with Applications symlink
make release    # dmg + notarize + staple
make install    # bundle + copy to /Applications
make run        # bundle + open .app
make format     # swift-format --recursive Sources/ --in-place
make clean      # remove build artifacts
```

## Code Quality

### Compiler settings (Package.swift)
- `.swiftLanguageMode(.v6)` - strict concurrency, data race safety at compile time
- `.defaultIsolation(MainActor.self)` - all types MainActor by default
- `.treatAllWarnings(as: .error)` - zero warnings policy

### Formatting
- `swift-format` (Apple's formatter, installed via Homebrew)
- Run `make format` before commits
- 2-space indentation (swift-format default)

### No external linters needed
The Swift 6 compiler with strict concurrency + warnings-as-errors catches more real bugs than SwiftLint. swift-format handles style consistency.

## Pre-Release Checklist

1. **Format**: `make format`
2. **Build**: `make build` - must compile with zero errors (warnings are errors)
3. **Bundle**: `make bundle` - creates signed .app with correct bundle ID
4. **Test install**: `make install && open /Applications/Blackbox.app`
5. **Verify permissions**: First launch should prompt for Screen Recording (as "Blackbox", not terminal)
6. **Test auto-recording**: Start any call (Zoom, Meet, etc.) - recording should start when microphone becomes active
7. **Test manual recording**: Menu > Record Now - should record and stop cleanly
8. **Test graceful quit**: Quit via menu while recording - file should be complete (not corrupted)
9. **Test settings**: All settings persist across restart, changes take effect within 5 seconds
10. **Check output files**: M4A files in ~/Library/Application Support/Blackbox/Recordings/, named with timestamp + app name, playable in QuickTime

## Release Process

Version is tracked in two places that must stay in sync:
- `Makefile` - `VERSION = X.Y.Z` (used for DMG filename)
- `Info.plist` - `CFBundleShortVersionString` (shown in app) + `CFBundleVersion` (build number)

Steps to release a new version:

```sh
# 1. Bump version in Makefile (VERSION) and Info.plist (CFBundleShortVersionString + CFBundleVersion)
# 2. Commit and push
git add -A && git commit -m "chore: bump version to X.Y.Z" && git push

# 3. Build, create DMG, notarize, and staple
make release

# 4. Generate Sparkle appcast signature
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update build/Blackbox-X.Y.Z.dmg)

# 5. Create GitHub release with DMG and appcast.xml
#    - Generate appcast.xml with version, DMG URL, signature, and file size
#    - Attach both the DMG and appcast.xml to the release
gh release create vX.Y.Z build/Blackbox-X.Y.Z.dmg appcast.xml \
  --title "Blackbox X.Y.Z" --notes "Release notes here"

# 6. Clean up local appcast.xml (it's a release asset, not tracked in repo)
rm -f appcast.xml
```

Notary uses keychain profile `blackbox` (configured via `xcrun notarytool store-credentials`).
Sparkle reads `SUFeedURL` from Info.plist pointing to `releases/latest/download/appcast.xml`.

## Key Architecture Decisions

- **Mic activity detection** drives recording lifecycle. CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` listener on the default input device fires when any app starts/stops using the microphone. A 3-second polling fallback catches cases where the listener doesn't fire (some audio pipelines). Auto-recordings capture system audio only (no mic) so detection stays clean - `DeviceIsRunningSomewhere` accurately reflects other apps' mic usage.
- **`nonisolated(unsafe)`** on AudioRecorder state because SCStreamOutput callbacks run on a background dispatch queue (`audioQueue`). Thread safety: `stop()` dispatches `markAsFinished()` on `audioQueue.sync` to serialize with callbacks.
- **Dual-track M4A**: system audio + mic as separate AVAssetWriterInputs. Most players mix both tracks on playback. Note: some players only play the first track.
- **`applicationShouldTerminate` returns `.terminateLater`** to allow async cleanup (finalizing AVAssetWriter) before process exit.
- **Auto-recovery**: `RecorderFailure` enum categorizes stream errors (mic failed, system stopped, permission denied). AudioMonitor auto-restarts on recoverable failures. Manual recordings also auto-restart.
- **Device following**: CoreAudio `AudioObjectAddPropertyListener` monitors default input device changes. `updateConfiguration()` switches mic seamlessly on running stream; falls back to stream restart on failure.
- **Crash safety**: `movieFragmentInterval` on AVAssetWriter writes fragment headers every 10s, making partial files recoverable.

## Concurrency Model

With `defaultIsolation(MainActor.self)`:
- All types are `@MainActor` by default (BlackboxApp, AudioMonitor, SettingsView)
- AudioMonitor is `@unchecked Sendable` for CoreAudio callback Unmanaged pointer dance
- AudioRecorder is `@unchecked Sendable` with `nonisolated(unsafe)` for callback state
- SCStreamOutput/SCStreamDelegate methods are `nonisolated` (called on background queues)
- Callbacks hop to MainActor via `Task { @MainActor in ... }`
