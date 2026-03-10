# Blackbox

macOS menu bar app that auto-records call audio using ScreenCaptureKit. Detects calls via CoreAudio microphone activity monitoring.

## Project Structure

```
Package.swift              - SPM manifest, macOS 15+, Swift 6.2
Sources/
  BlackboxApp.swift        - @main App, MenuBarExtra, Window scenes, AppDelegate
  AudioMonitor.swift       - @Observable: mic activity detection, auto/manual recording lifecycle
  AudioRecorder.swift      - SCStream + AVAssetWriter, dual-track capture + auto-mix on save
  MainWindowView.swift     - Main window: TabView with Recordings table + Settings
  SettingsView.swift       - Settings UI, defaults constants
  OnboardingView.swift     - First-launch onboarding: permissions walkthrough
  RecordingHUD.swift       - Floating NSPanel toast (top-right), recording start + save with click-to-reveal
  Log.swift                - OSLog + file logging, debug export
Info.plist                 - LSUIElement, NSMicrophoneUsageDescription
Makefile                   - build, bundle, dmg, release, install, run, format, test, check, clean
Tests/
  BlackboxTests.swift      - Swift Testing placeholder (framework ready, tests TBD)
.claude/skills/
  release-dmg/SKILL.md     - /release-dmg slash command for full release automation
```

## Build & Run

```sh
make build      # swift build -c release
make bundle     # build + create .app bundle + codesign
make dmg        # bundle + create DMG with Applications symlink
make release    # dmg + notarize + staple
make install    # bundle + copy to /Applications
make run        # bundle + open .app
make test       # swift test (Swift Testing framework)
make check      # format + build + test (full validation)
make format     # swift-format --recursive Sources/ Tests/ --in-place
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

## Testing

- **Framework**: Swift Testing (built into Swift 6.0+ toolchain)
- **Run**: `make test` or `swift test`
- **Test target**: `BlackboxTests` in `Tests/` directory
- **Isolation**: Same `defaultIsolation(MainActor.self)` as production code
- Tests require CLT framework search paths (configured in Package.swift via unsafeFlags)

## Pre-Release Checklist

1. **Automated**: `make check` (format + build + test)
2. **Manual smoke test**: `make install && open /Applications/Blackbox.app`
3. **Verify permissions**: First launch should prompt for Screen Recording (as "Blackbox", not terminal)
4. **Test auto-recording**: Start any call (Zoom, Meet, etc.) - recording should start when microphone becomes active
5. **Test manual recording**: Menu > Record Now - should record and stop cleanly
6. **Test graceful quit**: Quit via menu while recording - file should be complete (not corrupted)
7. **Test settings**: All settings persist across restart, changes take effect within 5 seconds
8. **Check output files**: M4A files in ~/Library/Application Support/Blackbox/Recordings/, named with timestamp + app name, playable in QuickTime

## Release Process

Use the `/release-dmg <version>` slash command to automate the full release pipeline.

The command handles: version bump (Makefile + Info.plist + CHANGELOG.md), format + build + test, DMG creation, Sparkle signing, git commit + push + tag, GitHub release with changelog notes and appcast.xml.

Version is tracked in two places that must stay in sync:
- `Makefile` - `VERSION = X.Y.Z` (used for DMG filename)
- `Info.plist` - `CFBundleShortVersionString` (shown in app) + `CFBundleVersion` (build number)

Notary uses keychain profile `blackbox` (configured via `xcrun notarytool store-credentials`).
Sparkle reads `SUFeedURL` from Info.plist pointing to `releases/latest/download/appcast.xml`.

## Key Architecture Decisions

- **Per-process mic detection** drives recording lifecycle. CoreAudio per-process APIs (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`) enumerate which specific processes have active mic input, filtering out Blackbox's own PID and ScreenCaptureKit XPC helpers (`com.apple.screencapturekit*`, `com.apple.replayd`). This allows auto-recordings to capture both system audio AND mic without a detection feedback loop. A 3-second polling fallback catches cases where listeners don't fire. Requires macOS 14.2+.
- **`nonisolated(unsafe)`** on AudioRecorder state because SCStreamOutput callbacks run on a background dispatch queue (`audioQueue`). Thread safety: `stop()` dispatches `markAsFinished()` on `audioQueue.sync` to serialize with callbacks.
- **Dual-track capture + auto-mix**: system audio + mic captured as separate AVAssetWriterInputs (standard ScreenCaptureKit pattern), then auto-mixed to single-track M4A on save via AVMutableComposition + AVAssetExportSession. The mix step atomically replaces the dual-track file. If mix fails, the dual-track file is kept as fallback. Virtual audio processors (Krisp, SoundSource, Loopback) are excluded from display-wide capture to prevent voice duplication.
- **`applicationShouldTerminate` returns `.terminateLater`** to allow async cleanup (finalizing AVAssetWriter + mix step) before process exit. 8-second timeout with `hasReplied` flag to prevent double-reply race.
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
