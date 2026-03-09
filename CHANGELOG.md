# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Per-process mic detection using macOS 14.2+ CoreAudio APIs (`kAudioProcessPropertyIsRunningInput`) - replaces system-wide `DeviceIsRunningSomewhere` listener
- Microphone capture on auto-recordings - both system audio and mic are now recorded during calls
- Call app name resolution from bundle ID (shown in HUD, notifications, and file names)
- Transcription service with Soniox integration (dual-track support for system + mic audio)
- Recordings detail view with built-in audio player and transcription UI
- NavigationSplitView layout for recordings (sidebar + detail pane)
- Soniox API key field in Settings

### Changed

- Auto-recordings now include microphone audio (previously system audio only)
- Recordings UI redesigned from flat table to split view with playback and transcription
- "Record Microphone" setting now applies to all recordings, not just manual ones
- `make run` now kills the previous Blackbox process before launching

### Fixed

- Menu bar countdown/elapsed timer font changed to `.monospacedDigit()` for stable width

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
