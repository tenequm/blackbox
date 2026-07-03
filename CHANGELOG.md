# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Inaudible mic track during FaceTime calls. When FaceTime's voice processing is active, the shared input device switches to a multichannel layout (3ch deinterleaved) where only channel 0 carries the mic and the extra channels are AEC metadata; the mono downmix averaged channel 0 with a near-silent metadata channel. Buffers with more than 2 channels now take channel 0 only (stereo still averages L/R), and a one-shot per-channel RMS diagnostic is logged when a multichannel layout appears.

## [0.9.0] - 2026-07-03

### Added

- Excluded Apps list in Settings: apps in the list never trigger automatic recording, even when they show call-like audio activity (mic + speaker active together). Excluding a parent app also covers its helper processes (e.g. Chrome helpers). Apps can be added from the running-apps menu (including menu-bar/accessory apps such as dictation tools) or via an "Other..." file picker for apps that aren't currently running. Contributed by @mugoosse (#12).
- Configurable date prefix for recording names (Settings > General): YYYY/YY/MM/DD tokens, default `YYMM-DD-`.

### Changed

- Transcription upgraded to Soniox `stt-async-v5` and no longer biases language detection toward English.

### Fixed

- Caller resolution is now a single shared pipeline, so app exclusion applies everywhere including suppression seeding, and a ~5s window where a just-excluded app could still start a recording is closed.

## [0.8.1] - 2026-05-06

### Fixed

- 5h46m ghost recording / 0-byte M4A when stop arrives during `AudioRecorder.start()`. Swift actor reentrancy let `stop()` flip a single `stopped` flag while `start()` was suspended on `SCShareableContent` (~12 s); the resumed start created a live recorder no caller held, dropped every buffer, and never finalized. `AudioRecorder` is now a four-phase machine (`notStarted` -> `starting` -> `running` -> `stopped`) with a `cancelRequested` flag checked after every `await`, and a take-and-nil cleanup that's safe under reentrancy. No failure path leaves an orphan directory or zero-byte file under `~/Library/Application Support/Blackbox/Recordings/`.
- `RecordingPipeline.start()` self-cleans on partial-init throws (metadata save, AVAssetWriter init, startWriting): the recording directory is removed before the error propagates, instead of being left behind for `pipeline.stop()` to ignore.
- Stop arriving during startup no longer surfaces an error toast. `AudioMonitor` pattern-matches `RecorderError.cancelled` and lost-race conditions silently; permission-denied and other real errors still surface.
- After a user-initiated stop (manual stop, force-stop on auto-recording), the same bundle no longer immediately re-triggers auto-record on the next 3 s poll. The resolved parent bundle ID is suppressed until it disappears from the active-caller set; other apps (e.g. Zoom while Chrome is suppressed) still trigger auto-record. Grace-expiry stops do not suppress, so a re-detected call still records.

### Added

- `RecorderError.cancelled` for stop-during-start cancellation.
- `StartCheckpoint` test seam in `AudioRecorder` and a `StartGate` actor for deterministic recorder-race tests.
- Docs: `docs/specification.md` D4 amended with the always-live WebRTC caveat; new D13 covers the recorder lifecycle invariant, monitor cooperation, and suppression semantics.

## [0.8.0] - 2026-04-24

### Added

- Layered mic recovery (D12). `AVAudioEngineConfigurationChange` (existing) is now supplemented by a CoreAudio `kAudioHardwarePropertyDefaultInputDevice` listener and a 1 Hz buffer-arrival watchdog (2 s stall threshold). All three sources funnel through `requestMicReinstall(source:)` → debounced mic-tap reinstall. Catches same-format default-input swaps that the AVAudioEngine notification silently misses.

### Changed

- Reverted system audio capture from CoreAudio Process Tap (CATap) back to display-wide `SCStream` (ScreenCaptureKit). v0.6.0's SCStream approach had an empirical production track record with zero silent-recording reports; CATap produced three distinct silent-recording bugs in 5 days (Bluetooth HFP 24kHz pin, IO-proc stop when nothing plays, Chrome Meet routed to non-default idle output). Root cause: aggregate-device IO proc fires on a hardware output-device clock that can be idle, pinned, or stalled. SCStream's clock comes from the OS-composited mix, decoupled from any specific device.
- System-audio track is now 2ch stereo 48 kHz 128 kbps AAC (was 1ch mono 64 kbps). Mic track remains 1ch mono 48 kHz 64 kbps. File size for a 30 min call: system track ~29 MB (was ~14 MB).
- Gap fill (D8), leading silence, and tail padding apply to the mic track only. System track has no synthesised silence - matches v0.6.0 which shipped without system-track gap fill for weeks.
- Onboarding now actively requests Screen Recording permission on completion via `CGRequestScreenCaptureAccess()`.
- Settings > Permissions row relabelled "Screen & System Audio Recording"; deep-links to the Screen Recording pane; uses `CGPreflightScreenCaptureAccess()` for live TCC state instead of a "recorded once" cache.

### Fixed

- Silent system-audio track on FaceTime (and any app routing through communication audio paths on macOS 26). SCStream delivers non-interleaved stereo Float32 CMSampleBuffers; the PCM round-trip helper inherited from the CATap era mis-copied non-interleaved payloads, producing system tracks with mean_volume near -66 dB. SCStream buffers are now appended directly to a stereo 128 kbps AAC writer input (v0.6.0 parity). Post-fix: FaceTime system track mean_volume -37.8 dB (from -66.4 dB); Chrome -27.1 dB.
- Full-hour mic-only recordings when default output was idle while Chrome Meet routed call audio to a non-default output via its in-page device picker.
- `AudioRecorder.stop()` now tears down the D12 default-input CoreAudio listener and watchdog timer (previously only removed in `deinit`'s defensive path). Closes a listener leak on `kAudioObjectSystemObject` that accumulated across recording sessions.
- Onboarding gate now treats `CGPreflightScreenCaptureAccess()` as the source of truth on every launch. First-run denial and post-install permission revocation both re-surface onboarding; prior behaviour sticky-marked onboarding complete even when the TCC prompt was denied.
- `mappedStartError` now routes SCStream `-3802`/`-3821` codes to `RecorderError.systemStopped` (new case), matching the in-flight `handleStreamStopped` routing.

### Removed

- CATap tap/aggregate-device/IO-proc pipeline, output-device change listener, IO proc buffer pool, and mic recovery-after-device-change paths.
- `AudioRecorder.pcmBuffer(from:)` (interleaved-only PCM helper - root cause of the FaceTime silence on macOS 26), `systemFormat` cache, `systemBuffersConversionFailed` counter.

## [0.7.0] - 2026-04-17

### Added

- CoreAudio Process Tap (CATap) system audio capture, replacing SCStream
- Hardware smoke test suite with file-based IPC test mode (`--ui-test-mode`) for automated real-audio validation
- `RecordingPipeline` type for AVAssetWriter management, gap filling, tail padding, and audio level metering (extracted from AudioRecorder for testability)
- `AudioMonitorDependencies` dependency injection with `TestClock` / `TestRecorderFactory` for deterministic call-detection tests
- Silence gap filling (D8) across both pipelines with clean LPCM format descriptions
- Device latency offset compensation (D9) for mic-system alignment
- Drift compensation via CATap `kAudioSubTapDriftCompensationKey`
- Output device change handling with aggregate device rebuild and silence gap filling
- Pre-allocated `AVAudioPCMBuffer` pool for CATap IO proc callback (RT-safe per spec D5)
- `AudioHardwareSystem` Swift wrappers (switf-macos) for typed CoreAudio access

### Changed

- Output is now 2-track M4A: system audio (1ch mono 48kHz) + mic (1ch mono 48kHz). Legacy 3-track recordings remain playable.
- `AudioRecorder` converted from class to `actor` with custom `DispatchSerialQueue` executor
- Call detection simplified to polling-only, removing ~140 lines of CoreAudio listener management
- macOS 26.1+, Swift 6.2, warnings-as-errors

### Fixed

- Chrome/WebRTC silent system-audio bug (eliminated by CATap architecture)
- Mic stall recovery after output device changes (mic is recreated if stalled post-rebuild)
- Track alignment: session starts on `max(first_sys_pts, first_mic_pts)` so both tracks begin with real content

### Known Issues

- Tail padding may report a short residual (up to several seconds) when macOS stalls output device routing mid-call. Tracked in #8.

## [0.6.0] - 2026-04-04

### Added

- Dual-SCStream recording: display-wide stream (guaranteed completeness) runs alongside per-app stream (cleaner AEC reference) simultaneously
- Per-app audio track in recordings when single caller detected (3-track M4A: display-wide + per-app + mic)
- Display and per-app audio buffer stats logging (received, appended, dropped, peak level)
- Track selector shows App option for 3-track recordings

### Changed

- AEC post-processing uses per-app track as reference when available (cleaner than display-wide)
- Transcription skips display-wide track in 3-track files to avoid doubling call audio
- Removed mid-recording restart logic (no more interrupted recordings from caller detection churn)

### Fixed

- Chrome/WebRTC calls producing silent system audio track (per-app SCStream of Chrome captures silence, display-wide now always present as fallback)

## [0.5.1] - 2026-03-16

### Fixed

- Mic audio recorded at 2x speed when device switches mid-recording (e.g. AirPods connecting during a call) - tap now resamples to 48kHz instead of passing native device rate to AVAssetWriter

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

[unreleased]: https://github.com/tenequm/blackbox/compare/v0.8.1...HEAD
[0.8.1]: https://github.com/tenequm/blackbox/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/tenequm/blackbox/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/tenequm/blackbox/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/tenequm/blackbox/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/tenequm/blackbox/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/tenequm/blackbox/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/tenequm/blackbox/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/tenequm/blackbox/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/tenequm/blackbox/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/tenequm/blackbox/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/tenequm/blackbox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/tenequm/blackbox/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tenequm/blackbox/releases/tag/v0.1.0
