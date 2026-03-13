# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-03-13

### Added

- Per-app audio capture: when a single calling app is detected, captures only that app's audio via SCContentFilter. Falls back to display-wide capture for multiple callers or unresolved apps
- Crash recovery watchdog helper (BlackboxWatchdog)
- AEC regression test suite and golden reference validation scripts
- App icon and screenshot in README

### Changed

- AEC post-processing streams chunk-by-chunk instead of loading entire tracks into memory (constant ~16KB vs ~3x recording size)

### Fixed

- Crash when Krisp switches audio devices during recording (ObjCTryBlock broken in release builds due to NS_NOESCAPE block optimization)
- Uncaught exception handler crash on background thread (inherited @MainActor isolation)
- Config change observer crash on CoreAudio I/O thread (inherited @MainActor isolation)
- Race between stop() and config change handlers causing concurrent AVAudioEngine mutation
- Zero-format (0Hz, 0ch) from inputNode during device transitions now rejected before installTap
- Rapid device switching causing unnecessary mic audio gaps (300ms debounce)

## [0.4.3] - 2026-03-11

### Added

- Mic diagnostic logging: input device name, permission status, and peak audio level logged per recording for debugging silent mic issues

## [0.4.2] - 2026-03-11

### Fixed

- False positive "Previous session crashed unexpectedly" error shown on every launch (crash detection flag was read after being overwritten)
- Mic track silent in recordings: AVAssetWriterInput was configured for 2-channel output but AVAudioEngine mic delivers 1-channel audio
- Mic buffer diagnostics: logs received/appended/dropped counts on recording stop for easier debugging

## [0.4.1] - 2026-03-11

### Fixed

- Crash on echo cancellation: DTLN-aec CoreML model bundle was not included in app bundle (only present in dev builds)
- Silent crashes now detected on next launch with error shown in menu bar
- Uncaught Objective-C exceptions now logged before process exit

### Changed

- Echo cancellation is now manual (button in recording detail view) instead of automatic on recording stop

## [0.4.0] - 2026-03-11

### Added

- Echo cancellation post-processing (DTLN-aec CoreML, 256-unit model) for cleaner mic recordings
- Original/Processed audio toggle in recording detail view (defaults to processed when available)
- Echo cancellation indicator icon in recordings list
- Waveform visualization in recording detail view (amplitude bars via Canvas, click/drag to seek)
- Track selector (Both/System/Mic) for playback controls
- System notification when Screen Recording permission is revoked during recording
- Input+output check for call detection (filters out dictation, Siri, voice memos)

### Changed

- Playback and transcription prefer echo-cancelled audio (`audio-processed.m4a`) when available
- Processed recordings stored at 16kHz mono AAC alongside originals for size savings and debugging
- Mic capture uses AVAudioEngine instead of SCStream `.microphone` (independent pipeline, automatic device following)
- Call detection uses polling-only (no CoreAudio property listeners)
- Dual-track M4A is now the final output format (no post-recording mixing)
- Display-wide audio capture no longer excludes any apps

### Fixed

- `dispatch_assert_queue_fail` crash in disk space monitor (MainActor isolation inherited by DispatchSource handler on audioQueue)
- Config change data race: AVAudioEngine handler now dispatches to audioQueue instead of running on arbitrary CoreAudio thread
- Format mismatch on mic device change: preserves original tap format so AVAssetWriterInput encoder doesn't fail mid-stream
- Inaccurate mic timestamps: uses AVAudioTime from tap callback via CMClockMakeHostTimeFromSystemUnits for proper multi-track sync
- Idle sleep could interrupt recording: changed ProcessInfo activity to `.userInitiated` (prevents sleep)
- Auto-recording not retried when initial start fails during active call
- Silent file loss on finishWriting timeout: now saves partial file (playable due to movieFragmentInterval)

### Removed

- Apple Voice Processing (`setVoiceProcessingEnabled`) - removed for reliability (VPIO aggregate device caused format issues)
- Post-recording audio mixing (AVMutableComposition + AVAssetExportSession)
- Virtual audio processor exclusion list (Krisp, SoundSource, Loopback)
- CoreAudio device change listener for mic following
- CoreAudio process list and per-process input listeners (~140 lines)
- Dead code: `Log.fault`, unused `TranscriptionService` error cases, stale `.blackbox` path checks

## [0.3.0] - 2026-03-10

### Added

- Per-process mic detection using macOS 14.2+ CoreAudio APIs (`kAudioProcessPropertyIsRunningInput`) - replaces system-wide `DeviceIsRunningSomewhere` listener
- Microphone capture on auto-recordings - both system audio and mic are now recorded during calls
- Call app name resolution from bundle ID (shown in HUD, notifications, and file names)
- Transcription service with Soniox integration
- Recordings detail view with built-in audio player and transcription UI
- NavigationSplitView layout for recordings (sidebar + detail pane)
- Soniox API key field in Settings
- M4A export for recordings (single-track copy, auto-mixes if multi-track)
- Real-time audio level metering with animated waveform icon in menu bar
- HUD-based error notifications with configurable duration
- Disk space pre-check (50 MB minimum) before starting a recording
- Restart rate limiting for auto-recovery (max 3 restarts per 30-second window)
- Virtual audio processor exclusion (Krisp, SoundSource, Loopback) to prevent voice duplication
- "Report a Bug" menu item (opens GitHub issues)
- Keyboard shortcuts for playback: Space (play/pause), Left/Right arrows (skip 15s)
- Low disk space monitoring during recording (warning at 500 MB, auto-stop at 100 MB)
- Polished DMG installer with proper icon layout via `create-dmg`
- Swift Testing framework setup (`make test`, `make check`)
- `/release-dmg` slash command for automated release pipeline

### Changed

- Recording uses dual-track capture (system audio + mic as separate AVAssetWriterInputs) with auto-mix to single-track M4A on save via AVMutableComposition
- Recordings stored as plain directories instead of `.blackbox` macOS package bundles
- Transcription uses Soniox `stt-async-v4` model with mix-first approach (multi-track files mixed before upload)
- Auto-recordings now include microphone audio (previously system audio only)
- Recordings UI redesigned from flat table to split view with playback and transcription
- "Record Microphone" setting now applies to all recordings, not just manual ones
- `make run` now kills the previous Blackbox process before launching
- Notifications switched from system banners (UNUserNotification) to in-app HUD toasts
- "Recording Saved" HUD click now opens the main window instead of Finder
- Soniox API key stored in macOS Keychain instead of UserDefaults (with one-time migration)
- Transcription file upload uses streaming (64 KB chunks) instead of loading entire file into memory
- Auto-recording now degrades gracefully on mic failure (continues without mic instead of stopping)

### Removed

- `.blackbox` bundle format and UTI declaration
- One-time migration from flat `.m4a` to `.blackbox` format (no longer needed)

### Fixed

- Voice duplication when using Krisp or other virtual audio processors
- Soniox speaker field parsing (v4 API returns String, not Int)
- Transcription quality - proper speaker diarization with timestamps instead of single text blob
- `stop()` no longer returns URL for corrupt files (guards on `writer.status == .completed`)
- AVAssetWriter failure during recording now triggers auto-recovery instead of silently truncating
- `applicationShouldTerminate` double-reply race prevented with `hasReplied` flag
- Menu bar audio level icons use valid SF Symbols (`speaker.wave.1`/`.2`/`.3`)
- Removed unnecessary `.screen` output registration from SCStream (wasted GPU resources)
- Menu bar countdown/elapsed timer font changed to `.monospacedDigit()` for stable width
- Auto-recording now starts after manual recording stops during an active call
- HUD click handler fires only once (was possible to double-fire on rapid clicks)
- Dropped audio buffers are now logged for diagnostic purposes
- Recordings list debounced on window activation (prevents redundant disk scans)

## [0.2.0] - 2026-03-09

### Added

- Release pipeline with notarization, stapling, and Sparkle appcast
- DMG creation with Applications symlink

## [0.1.0] - 2026-03-08

### Added

- Auto-recording triggered by microphone activity detection
- Manual recording via menu bar
- Dual-track M4A output (system audio + mic)
- Recording HUD with start/save notifications
- Grace period for call resumption detection
- Auto-recovery on stream failures
- Device following (seamless mic switching)
- Crash-safe recordings via movie fragment intervals
- Onboarding flow with permissions walkthrough
- Settings: launch at login, grace period, save directory, notifications
- Structured logging with os.Logger + file sink
- Sparkle auto-update support
- Developer ID code signing

[unreleased]: https://github.com/tenequm/blackbox/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/tenequm/blackbox/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/tenequm/blackbox/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/tenequm/blackbox/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/tenequm/blackbox/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/tenequm/blackbox/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/tenequm/blackbox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/tenequm/blackbox/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tenequm/blackbox/releases/tag/v0.1.0
