# Blackbox

macOS menu bar app that auto-records call audio from target apps (Chrome, Zoom) using ScreenCaptureKit.

## Project Structure

```
Package.swift              - SPM manifest, macOS 15+, Swift 6.2
Sources/
  BlackboxApp.swift        - @main App, MenuBarExtra, Settings scene, AppDelegate
  AudioMonitor.swift       - @Observable: process/window monitoring, recording lifecycle
  AudioRecorder.swift      - SCStream + AVAssetWriter, dual-track M4A
  SettingsView.swift       - Settings UI, defaults constants
Info.plist                 - LSUIElement, NSMicrophoneUsageDescription
Makefile                   - build, bundle, install, run, format, clean
```

## Build & Run

```sh
make build      # swift build -c release
make bundle     # build + create .app bundle + codesign
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
6. **Test auto-recording**: Open Chrome, navigate to Google Meet - recording should start when meeting window detected
7. **Test manual recording**: Menu > Record Now > pick app - should record and stop cleanly
8. **Test graceful quit**: Quit via menu while recording - file should be complete (not corrupted)
9. **Test settings**: All settings persist across restart, changes take effect within 3 seconds
10. **Check output files**: M4A files in ~/Documents/Blackbox/, named with timestamp + app name, playable in QuickTime

## Key Architecture Decisions

- **Window title detection** (not audio silence) drives recording lifecycle. `CGWindowListCopyWindowInfo` checks for meeting patterns like "Meet -" or "Zoom".
- **`nonisolated(unsafe)`** on AudioRecorder state because SCStreamOutput callbacks run on a background dispatch queue (`audioQueue`). Thread safety: `stop()` dispatches `markAsFinished()` on `audioQueue.sync` to serialize with callbacks.
- **Dual-track M4A**: system audio + mic as separate AVAssetWriterInputs. Most players mix both tracks on playback. Note: some players only play the first track.
- **`applicationShouldTerminate` returns `.terminateLater`** to allow async cleanup (finalizing AVAssetWriter) before process exit.

## Concurrency Model

With `defaultIsolation(MainActor.self)`:
- All types are `@MainActor` by default (BlackboxApp, AudioMonitor, SettingsView)
- AudioRecorder is `@unchecked Sendable` with `nonisolated(unsafe)` for callback state
- SCStreamOutput/SCStreamDelegate methods are `nonisolated` (called on background queues)
- Callbacks hop to MainActor via `Task { @MainActor in ... }`
