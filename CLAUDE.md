# Blackbox

macOS menu bar app that auto-records call audio. Detects calls via CoreAudio per-process audio state polling. Captures system audio via CATap (CoreAudio Process Tap) and mic via AVAudioEngine as independent pipelines.

## Project Structure

```
Package.swift              - SPM manifest, macOS 15+, Swift 6.2
Sources/
  BlackboxApp.swift        - @main App, MenuBarExtra, Window scenes, AppDelegate
  AudioMonitor.swift       - @Observable: call detection (polling), auto/manual recording lifecycle
  AudioRecorder.swift      - CATap (system audio) + AVAudioEngine (mic) + AVAssetWriter, dual-track capture
  AECProcessor.swift       - DTLN-aec CoreML post-processing: echo cancellation on mic track
  MainWindowView.swift     - Main window: TabView with Recordings table + Settings
  SettingsView.swift       - Settings UI, defaults constants
  OnboardingView.swift     - First-launch onboarding: permissions walkthrough
  RecordingHUD.swift       - Floating NSPanel toast (top-right), recording start + save with click-to-reveal
  Log.swift                - OSLog + file logging, debug export
Info.plist                 - LSUIElement, NSAudioCaptureUsageDescription, NSMicrophoneUsageDescription
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

## Logs

App logs: `~/Library/Logs/Blackbox/blackbox.log`
Crash reports: `~/Library/Logs/DiagnosticReports/Retired/Blackbox-*.ips`

## Pre-Release Checklist

1. **Automated**: `make check` (format + build + test)
2. **Manual smoke test**: `make install && open /Applications/Blackbox.app`
3. **Verify permissions**: First recording should prompt for System Audio Recording permission
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

- **Polling-only call detection** drives recording lifecycle. Every 3 seconds, CoreAudio per-process APIs enumerate processes with BOTH `IsRunningInput` AND `IsRunningOutput` (filtering out own PID). Input+output check identifies actual calls, filtering out dictation/Siri/voice memos. No CoreAudio property listeners - polling-only eliminates ~140 lines of listener management code. Requires macOS 14.2+.
- **CATap system audio capture**: CoreAudio Process Tap (`AudioHardwareCreateProcessTap`) via private aggregate device captures all system audio, excluding own PID via `CATapDescription(stereoGlobalTapButExcludeProcesses:)`. IO proc callback on aggregate device delivers interleaved Float32 AudioBufferList, converted to CMSampleBuffer and dispatched to `audioQueue` for writing. Drift compensation enabled via `kAudioSubTapDriftCompensationKey`. Output device changes trigger aggregate rebuild with silence gap filling (D8). Requires `NSAudioCaptureUsageDescription` in Info.plist.
- **AVAudioEngine mic capture**: Independent mic pipeline via `inputNode.installTap()`. Can fail without affecting system audio. Device following via `AVAudioEngineConfigurationChange` notification (reinstalls tap, sub-second gap, same file). Device latency offset (D9) applied as PTS shift to align mic with system audio.
- **`nonisolated(unsafe)`** on AudioRecorder state because CATap IO proc callbacks and AVAudioEngine tap callbacks (dispatched to `audioQueue`) run on background threads. Thread safety: all writer state accessed exclusively on serial `audioQueue`.
- **2-track M4A**: Track 0 = system audio (2ch stereo). Track 1 = mic (1ch mono, when mic enabled). Session starts on first system audio sample; mic samples before that are dropped. Legacy 3-track recordings (pre-v0.7.0) remain playable.
- **Echo cancellation post-processing**: After recording stops, DTLN-aec CoreML (256-unit model) processes the mic track using the system audio track (track 0) as the AEC reference. Writes `audio-processed.m4a` alongside the original. Fire-and-forget: errors are logged, original is never modified.
- **`applicationShouldTerminate` returns `.terminateLater`** to allow async cleanup (stop AVAudioEngine, destroy CATap aggregate/tap, finalize AVAssetWriter) before process exit. 8-second timeout with `hasReplied` flag to prevent double-reply race.
- **Auto-recovery**: `RecorderFailure` enum categorizes stream errors (system stopped, permission denied). AudioMonitor auto-restarts on recoverable failures.
- **Crash safety**: `movieFragmentInterval` on AVAssetWriter writes fragment headers every 10s, making partial files recoverable.

## Concurrency Model

With `defaultIsolation(MainActor.self)`:
- All types are `@MainActor` by default (BlackboxApp, AudioMonitor, SettingsView)
- AudioMonitor is purely MainActor-isolated (no `@unchecked Sendable` needed - polling-only, no C callbacks)
- AudioRecorder is `@unchecked Sendable` with `nonisolated(unsafe)` for callback state on `audioQueue`
- CATap IO proc callback copies audio data and dispatches to `audioQueue` for CMSampleBuffer conversion and writing
- Output device change listener dispatches to `audioQueue` for aggregate device rebuild
- AVAudioEngine tap callback dispatches to `audioQueue` via `audioQueue.async` to serialize with CATap callbacks
- AVAudioEngine config change observer is `nonisolated` (fires on NotificationCenter delivery thread, dispatches to `audioQueue` for thread safety)
