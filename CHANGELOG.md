# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Per-process mic detection using macOS 14.2+ CoreAudio APIs (`kAudioProcessPropertyIsRunningInput`) - replaces system-wide `DeviceIsRunningSomewhere` listener
- Microphone capture on auto-recordings - both system audio and mic are now recorded during calls
- Call app name resolution from bundle ID (shown in HUD, notifications, and file names)
- Transcription service with Soniox integration (dual-track support for system + mic audio)
- Recordings detail view with built-in audio player and transcription UI
- NavigationSplitView layout for recordings (sidebar + detail pane)
- Soniox API key field in Settings
- `.blackbox` directory bundle format for recordings (audio.m4a + metadata.json + transcript.json per recording)
- UTI declaration for `.blackbox` recording package type (`com.tenequm.blackbox.recording`)
- One-time migration from flat `.m4a` files to `.blackbox` directory format
- Real-time audio level metering with animated waveform icon in menu bar
- HUD-based error notifications with configurable duration
- Disk space pre-check (50 MB minimum) before starting a recording
- Restart rate limiting for auto-recovery (max 3 restarts per 30-second window)

### Changed

- Auto-recordings now include microphone audio (previously system audio only)
- Recordings UI redesigned from flat table to split view with playback and transcription
- "Record Microphone" setting now applies to all recordings, not just manual ones
- `make run` now kills the previous Blackbox process before launching
- Notifications switched from system banners (UNUserNotification) to in-app HUD toasts
- "Recording Saved" HUD click now opens the main window instead of Finder
- Soniox API key stored in macOS Keychain instead of UserDefaults (with one-time migration)
- Transcription file upload uses streaming (64 KB chunks) instead of loading entire file into memory
- Auto-recording now degrades gracefully on mic failure (continues without mic instead of stopping)

### Fixed

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

[unreleased]: https://github.com/tenequm/blackbox/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tenequm/blackbox/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tenequm/blackbox/releases/tag/v0.1.0
