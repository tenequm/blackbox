# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[unreleased]: https://github.com/tenequm/blackbox/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/tenequm/blackbox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/tenequm/blackbox/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tenequm/blackbox/releases/tag/v0.1.0
