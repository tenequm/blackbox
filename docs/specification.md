# Blackbox Audio Architecture Specification

This document records architectural decisions and their reasoning. Implementation details live in the code and CLAUDE.md. When in doubt, reliability wins over features.

## Design Principles

1. **Reliability over features.** A recording that silently fails is worse than a missing feature. Every architectural choice prioritizes "does the file get written correctly?"
2. **Independent failure domains.** System audio and mic capture are decoupled pipelines. Either can fail without taking down the other.
3. **Minimal moving parts.** Prefer polling over event-driven listeners. Prefer no post-processing over post-processing. Fewer code paths means fewer bugs.
4. **Let the OS do the work.** Use AVAudioEngine's automatic device following instead of manual CoreAudio listeners. Don't reimplement what the platform provides.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DETECTION                                    │
│                                                                     │
│  Poll every 3 seconds:                                              │
│    Scan CoreAudio process list                                      │
│    Find processes with BOTH IsRunningInput AND IsRunningOutput      │
│    Filter out: own PID                                              │
│    If found → call detected → start recording                      │
│    If none  → grace period  → stop recording                       │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        CAPTURE                                      │
│                                                                     │
│  ┌────────────────────────┐       ┌──────────────────────────────┐  │
│  │  SCStream (ScreenCap)  │       │     AVAudioEngine            │  │
│  │                        │       │                              │  │
│  │  Display-wide system   │       │  Mic via inputNode tap       │  │
│  │  audio (video disabled)│       │  Follows system default      │  │
│  │  Excludes own PID      │       │                              │  │
│  │                        │       │  PTS offset-compensated      │  │
│  │                        │       │  via device latency query    │  │
│  └───────────┬────────────┘       └──────────────┬───────────────┘  │
│              │                                   │                  │
│              ▼                                   ▼                  │
│         CMSampleBuffer                     CMSampleBuffer           │
│         (sample handler queue)             (from PCM + hostTime     │
│              │                              - latency offset)       │
│              │                                   │                  │
└──────────────┼───────────────────────────────────┼──────────────────┘
               │                                   │
               ▼                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│              RESAMPLE & DOWNMIX (mic track only)                    │
│                                                                     │
│  resampleToMono48k(): stereo→mono downmix (L+R avg),                │
│  sample rate conversion via linear interpolation to 48kHz.          │
│  Mic pipeline outputs 1ch mono Float32 at 48kHz.                    │
│  System pipeline (SCStream) bypasses this stage - stereo passthrough│
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│           GAP DETECTION & FILL (mic track only)                     │
│                                                                     │
│  Mic: track nextExpectedTime from PTS + duration                    │
│  If incoming PTS > expected → write zero-filled silence buffers     │
│  Tail padding: pad shorter mic tail to common end time on stop      │
│  System: SCStream CMSampleBuffer appended directly, no gap fill     │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        WRITING                                      │
│                                                                     │
│  AVAssetWriter → 2 track M4A (AAC, 48kHz)                          │
│    Track 0: system audio (2ch stereo, 128kbps)                      │
│    Track 1: mic audio (1ch mono, 64kbps)                            │
│  movieFragmentInterval = 10s (crash safety)                         │
│  No post-processing, no mixing                                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Architecture Evolution

**v0.1-v0.4 (Feb 2026):** Single SCStream for system audio, AVAudioEngine for mic. CoreAudio listeners for call detection. Post-recording mixing to single-track. Basic but functional.

**v0.5 (Mar 2026):** Simplified call detection to polling-only (D3), added input+output check (D4), removed post-recording mixing (D2). Chose AVAudioEngine over SCStream `.microphone` for mic (D1) - automatic device following eliminated ~140 lines of listener code.

**v0.6.0 (Mar 2026):** Chrome/WebRTC silence bug discovered - per-app SCStream delivers silence for Chrome calls due to private audio routing. Added display-wide SCStream as safety net, keeping per-app as best-effort AEC reference. Output became variable 2-3 track M4A. Added DTLN-aec CoreML post-processing for echo cancellation (D7).

**v0.6.1 (Apr 2026):** Smoke testing revealed 8.64s desync over a 2-hour recording - AVAssetWriter collapses PTS gaps from mic device switches. Implemented silence gap filling (D8) to preserve timeline integrity across both pipelines.

**v0.7.0 (Apr 2026):** CATap migration (D5) replaces dual SCStream. Per-app track dropped. Fixed 2-track M4A (both tracks 1ch mono 48kHz 64kbps - system audio downmixed from stereo via `resampleToMono48k`). Device latency offset compensation (D9). Requires macOS 26.1+. Adopted CoreAudio Swift wrappers (`AudioHardwareSystem`, `AudioHardwareTap`, `AudioHardwareAggregateDevice`, `AudioHardwareProcess`) eliminating ~170 lines of C-level CoreAudio boilerplate. Converted AudioRecorder from class to Swift 6.2 actor with custom `DispatchSerialQueue` executor, replacing all `nonisolated(unsafe)` declarations with compile-time actor isolation safety. Fixed mic latency offset to use actual device sample rate and `AudioConvertNanosToHostTime` for correct Mach time conversion. Extracted `RecordingPipeline` from `AudioRecorder` (AVAssetWriter management, gap filling, tail padding, audio level metering) for testability. Introduced `AudioMonitorDependencies` for dependency injection into `AudioMonitor`, enabling deterministic integration tests with `TestClock` and `TestRecorderFactory`. Added hardware smoke tests via `BlackboxTestMode` file-based IPC - launches real app bundle, drives recording, verifies output file structure.

**v0.8.0 (Apr 2026):** Reverted system audio capture from CATap back to display-wide SCStream (D10 supersedes D5). CATap produced three distinct silent-recording bugs in 5 days, all rooted in aggregate-device clock-source fragility (hardware output clock idle/pinned/stalled). Display-wide SCStream's clock is OS-composited, decoupled from any specific device; it had a production track record in v0.6.0 with zero silent-recording reports. Onboarding actively requests Screen Recording permission via `CGRequestScreenCaptureAccess()`. Restored v0.6.0's direct-append ingest shape (D11): SCStream CMSampleBuffers are appended to a stereo 128 kbps AAC writer input with no PCM round-trip or downmix, fixing a latent non-interleaved-stereo mis-copy that produced silent FaceTime recordings under the v0.7.0/v0.8.0-internal ingest helper. Gap fill (D8), leading silence, and tail padding now run on the mic track only. All v0.7.0 infrastructure improvements preserved (actor model, RecordingPipeline, AudioMonitorDependencies DI, hardware smoke tests, D9 latency offset).

---

## Key Architectural Constraints

These are non-obvious constraints discovered during implementation that future changes must respect.

- **AVAssetWriterInput format is immutable.** The internal encoder configures from the first appended buffer's format description. Mid-stream format changes cause `append()` to fail and the writer to enter `.failed` state, losing both tracks. This is why the mic tap must reinstall with the original format on device change.

- **AVAssetWriter collapses PTS gaps.** When audio buffers have a timestamp discontinuity (gap between last buffer's end and next buffer's start), the writer concatenates samples back-to-back, making the track shorter. Gaps must be filled with explicit zero-filled silence buffers to preserve timeline integrity. No AVAssetWriter setting changes this behavior. The writer also performs no clock domain normalization - it assumes all inputs share the same timeline.

- **`AVAudioEngineConfigurationChange` can miss same-format default-input switches.** The engine's hidden default-input aggregate is only rebuilt when the new hardware forces a format change; when the default input swaps between two same-format devices (two 48 kHz mics, monitor auto-claiming default, same-format USB fallback), the aggregate silently re-points, the engine keeps pulling from the old HAL endpoint, no notification fires, and mic capture stalls. Reproduced in the v0.8.0 smoke suite. Reliability requires a supplemental `kAudioHardwarePropertyDefaultInputDevice` listener plus a buffer-arrival watchdog; see D12.

- **SCStream and AVAudioEngine use different clock sources.** SCStream's sample handler delivers audio timestamped against the host time clock (`mach_absolute_time`) from the OS-composited mix. AVAudioEngine's mic runs on the input device's clock, also mapped to host time. Theoretical worst-case drift between hardware clocks is ~50 PPM (~180ms/hour), but empirical testing shows negligible actual clock rate difference (0.049s over 7233s in a 2-hour recording). The apparent "drift" in practice comes from two independent sources: (1) PTS gap collapse during device switches, where AVAssetWriter concatenates samples and shortens the track (solved by D8 silence filling), and (2) a constant pipeline latency offset (~20-70ms) between the SCStream sample-handler and AVAudioEngine delivery paths (compensated by D9).

- **Under `.defaultIsolation(MainActor.self)`, an unannotated protocol is `@MainActor`, and so are its requirements.** This is what puts async work on the main thread here, and it is not what it looks like: `nonisolated` on the conforming *type* is irrelevant to it. Measured on this target's flags (`-swift-version 6 -default-isolation MainActor`, Swift 6.3.3), calling from the main actor: a `nonisolated` free async function runs **off** main; a plain async method on a `nonisolated final class`, called on the concrete type, runs **off** main; the same method reached through a protocol declared without `nonisolated` runs **on** main; through a protocol declared `nonisolated`, **off** main; through a requirement marked `@concurrent`, **off** main. So the fix is a property of the protocol, not of the witness - `TranscriptionServicing` annotates all five of its requirements `@concurrent`, and declaring the protocol `nonisolated` would have worked equally well. Without one of those, transcript JSON decoding and every poll response parse on the main thread. Note this constraint was documented wrongly twice before being measured: first as "marking the class `nonisolated` is not enough" (the class is not the reason), then as "`-default-isolation MainActor` produces the caller-inheriting semantics of `NonisolatedNonsendingByDefault`" (it does not - anything actually spelled `nonisolated` hops off main under the flag; `nonisolated(nonsending)` is that behaviour and is spelled separately).

- **`FileManager.contentsOfDirectory(at:)` resolves symlinks in its base.** Given `/var/folders/...` it returns children spelled `/private/var/folders/...`, while URLs built by appending to the caller's own base keep the original spelling. Anything that keys state by path (transcription job status does) must enumerate by name via `contentsOfDirectory(atPath:)` instead - `RecordingStore.directories(in:)` is the single implementation.

- **Swift's synthesized `Codable` throws on a missing key even when the property has a default.** A `var flag: Bool = false` does not decode as `false` when the key is absent; `init(from:)` fails outright. Combined with a `try?` at the call site, adding a field to a persisted struct silently drops every record an earlier build wrote. `TranscriptionJob` therefore hand-writes `init(from:)` with `decodeIfPresent` for every key, because dropping one of its records strands the audio it names on a third-party server with nothing left to identify it. The repo cannot test this directly - defining `init(from:)` suppresses synthesis, so the tests exercise the hand-written decoder - but a scratch program confirms the synthesized one throws `keyNotFound` for a missing defaulted key.

- **CoreAudio per-process APIs require macOS 14.2+.** `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`. Available at the current macOS 26.1+ deployment target. Used only for call detection (D3/D4), not for capture.

- **Screen Recording permission can be revoked at any time.** macOS 15+ introduced recurring ("monthly") re-authorization prompts for Screen Recording, inherited by macOS 26. When permission is lost mid-recording, `SCStream` stops with NSError code -3801 (mapped to `RecorderFailure.permissionDenied`). AVAudioEngine mic capture is unaffected and continues independently. The AudioMonitor restart budget treats permission loss as terminal (no auto-restart), and the user is notified via system notification (D6).

---

## Permissions

Two TCC permissions required:

- **Screen Recording** - for SCStream system audio capture. No entitlement, runtime-only. Check via `CGPreflightScreenCaptureAccess()`; request via `CGRequestScreenCaptureAccess()` in onboarding. On macOS 26.1+, the Screen Recording grant also covers audio capture, so no separate prompt is required. `NSAudioCaptureUsageDescription` is still present in `Info.plist` as a defensive fallback for any OS path that checks it.
- **Microphone** - for AVAudioEngine mic capture. Requires `NSMicrophoneUsageDescription` in Info.plist. If denied, system audio still records.

macOS 26+ uses the `com.apple.settings.PrivacySecurity.extension` URL scheme for System Settings deep links (replaces `com.apple.preference.security`).

---

## Decision Log

Architectural decisions with reasoning and alternatives considered.

### D1: AVAudioEngine for mic instead of SCStream .microphone

**Decision:** Use AVAudioEngine tap on inputNode for mic capture, independent from system audio capture.

**Alternatives considered:**
- **SCStream `.microphone`** (macOS 15+): requires manual device following via CoreAudio listener + `updateConfiguration()`. On failure, recording splits into separate files. Tied to SCStream lifecycle. Documented bugs with corrupted files and XPC PID uncertainty.
- **AVCaptureSession + AVCaptureAudioDataOutput**: gives CMSampleBuffer natively (no conversion), structured interruption notifications. But requires manual device switching - doesn't solve the core problem.

**Why AVAudioEngine wins:** Automatic device following via inputNode. One `AVAudioEngineConfigurationChange` notification handler replaces ~140 lines of CoreAudio listener management. Device switches cause a sub-second gap in the same file instead of a recording split. Independent from SCStream system audio pipeline - mic survives SCStream stop/restart.

**Device switch gap is unavoidable.** When `AVAudioEngineConfigurationChange` fires, the engine has already stopped itself internally. The tap must be removed and reinstalled with the new device's format. This is a platform limitation - the engine cannot survive a sample rate or channel count change without a restart. The 300ms debounce (for Krisp's rapid-fire config changes) dominates the gap duration; the actual reinstall takes <10ms. See D8 for how these gaps are filled with silence to prevent track desync.

**Tradeoff accepted:** ~30 lines of AVAudioPCMBuffer-to-CMSampleBuffer conversion boilerplate (existing `asSampleBuffer()` extension). Timestamps use `AVAudioTime.hostTime` (`mach_absolute_time`, wall clock) converted via `CMClockMakeHostTimeFromSystemUnits`, then adjusted by the device latency offset (D9) for alignment with SCStream system audio.

### D2: Remove post-recording audio mixing

**Decision:** Keep multi-track M4A as final output. No mixing step. Always 2 tracks (system audio + mic).

**Previous implementation:** AVMutableComposition + AVAssetExportSession mixed dual-track to single-track after recording stopped.

**Why removed:** Four failure points at save time (load asset, create composition, run export session, atomic file replace). Blocks the save path. All modern players and transcription tools handle multi-track M4A. If single-track is ever needed, it should happen on export/share, not on save.

### D3: Polling-only call detection (remove CoreAudio listeners)

**Decision:** Detect calls by polling every 3 seconds. No CoreAudio property listeners.

**Previous implementation:** Event-driven CoreAudio listeners (process list + per-process IsRunningInput) with 3-second polling fallback.

**Why polling-only:** The polling fallback existed because listeners don't fire reliably for all audio pipelines - we already didn't trust them. Listeners added ~140 lines of code (N per-process listeners, Unmanaged pointer management, deinit cleanup, nonisolated(unsafe) state) for at best a few seconds of faster detection. For calls lasting minutes to hours, 0-3 second detection delay is imperceptible.

### D4: Input AND output check for call detection

**Decision:** A call is detected when a process has both `IsRunningInput` (mic active) AND `IsRunningOutput` (audio playing), excluding our own PID.

**Previous implementation:** Input-only check, which triggered on dictation, Siri, voice memos, voice search.

**Why both:** Input+output together identifies processes that are both capturing mic and playing audio - the defining characteristic of a call. Filters out most false positives without maintaining a hardcoded list of known call apps.

**Caveat:** Always-live WebRTC tabs (Chrome "metaverse office", Discord, etc.) can hold both flags continuously even when no human is talking. The detection check itself cannot rule those out, so the recorder lifecycle (D13) and post-stop suppression carry the burden: stop is honored regardless of caller flap, and a manually-stopped bundle is filtered from the eligible-caller set until it actually disappears for one poll.

### D5: CATap for system audio (replaces dual SCStream) [SUPERSEDED by D10 in v0.8.0]

**Decision:** Use CoreAudio Process Tap via Swift wrappers (`AudioHardwareSystem.shared.makeProcessTap`) and an aggregate device for all system audio capture. Replaces the previous dual-SCStream architecture (display-wide + per-app).

**Previous implementation:** Two SCStream instances - display-wide (critical) + per-app (best-effort) writing to 2-3 track M4A. Per-app track existed to provide a cleaner AEC reference, but was unreliable (Chrome/WebRTC silence bug) and added complexity without real-world benefit.

**Why CATap over SCStream:**
- **Better permission model.** `NSAudioCaptureUsageDescription` grants audio-only permission with a one-click grant. SCStream required Screen Recording permission (broad, confusing for users, requires app restart, subject to macOS 15+ monthly re-auth). RecordKit (Nonstrict) made CATap their default backend in v0.82.0 for this reason.
- **No Chrome/WebRTC silence bug.** CATap captures at the HAL level, below any private audio routing that caused per-app SCStream to deliver silence for Chrome/WebRTC apps.
- **Lower latency.** IO proc callback runs on a real-time thread, delivering audio with less buffering than SCStream's sample handler queue.
- **Built-in drift compensation.** `kAudioSubTapDriftCompensationKey: true` on the aggregate device tap list enables CoreAudio's hardware-level clock synchronization for the system audio tap.
- **Simpler pipeline.** One capture stream instead of two SCStreams. Fixed 2-track output (system + mic) instead of variable 2-3 tracks.

**Setup sequence:**
1. Get own process via `AudioHardwareSystem.shared.process(for: pid)`
2. Create `CATapDescription(stereoGlobalTapButExcludeProcesses:)` excluding own PID
3. Create tap via `system.makeProcessTap(description:)` - returns `AudioHardwareTap`
4. Create private aggregate device via `system.makeAggregateDevice(description:)` with tap in `kAudioAggregateDeviceTapListKey` and `kAudioSubTapDriftCompensationKey: true`
5. Create IO proc via `AudioDeviceCreateIOProcIDWithBlock` on `aggregate.id` (no Swift wrapper for IO proc creation)
6. Start with `aggregate.start(IOProcID:)`

**IO proc callback:** Receives interleaved Float32 `AudioBufferList` on a real-time thread. Must be RT-safe (no allocations, no ObjC messaging, no locks without priority donation).

**Sample rate policy:** The aggregate device's nominal rate is dictated by the output subdevice (e.g. AirPods HFP pins it at 24kHz, built-in speakers at 48kHz). We read `kAudioDevicePropertyNominalSampleRate` on the aggregate and build the IO proc callback format from that rate - we do not try to write it. Chromium's "force 48kHz" approach is a silent no-op when the output subdevice pins the rate: `AudioObjectSetPropertyData` returns `noErr` while the subsequent read-back shows the unchanged rate. If we then wrap IO proc buffers with a 48kHz format while the callback delivers 24kHz frames, the audio is labeled at 2x its true rate and resampling misfires - producing a file that is half silence and half 2x-sped-up content. `resampleToMono48k` already handles any source rate via linear interpolation, so following the aggregate's rate on the hot path is the correct strategy.

**AudioBufferList-to-CMSampleBuffer conversion:** The IO proc receives raw interleaved Float32 `AudioBufferList`. Conversion on `audioQueue`:
1. Zero-copy wrap via `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator:nil)`, then copy frame data (IO proc buffer only valid during callback)
2. Resample and downmix to mono 48kHz via `RecordingPipeline.resampleToMono48k()` (stereo L+R average, linear interpolation for rate conversion)
3. Convert to `CMSampleBuffer` via `asSampleBuffer(timestamp:)` using `AVAudioTime.hostTime` converted via `CMClockMakeHostTimeFromSystemUnits`
4. Pass to `RecordingPipeline.appendSystemSample()` for gap detection and writing

**Output device change:** When the system default output device changes, the tap's aggregate device must be torn down and rebuilt. This causes a gap in system audio (~0.5-1.5s), handled by silence gap filling (D8). Listen for `kAudioHardwarePropertyDefaultOutputDevice` changes.

**Teardown sequence (on recording stop):**
1. Stop IO proc: `aggregate.stop(IOProcID:)`
2. Destroy IO proc: `AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)` (no Swift wrapper)
3. Destroy aggregate device: `system.destroyAggregateDevice(aggregate)`
4. Destroy process tap: `system.destroyProcessTap(tap)`
5. Remove output device change listener
6. Order matters - destroying the aggregate before stopping the IO proc can crash. Wrappers have explicit lifecycle (not RAII) - must call destroy before nilling the reference

**CATap permission denial behavior:** If `NSAudioCaptureUsageDescription` is missing from Info.plist, `AudioHardwareCreateProcessTap` succeeds but the tap delivers silence with NO error. The recording appears to work but contains no audio. Always verify the Info.plist key exists. If the user denies the permission prompt, `AudioHardwareCreateProcessTap` returns `kAudioHardwareBadObjectError` (-66580).

**Aggregate device mic list filtering:** The CATap aggregate device may appear in the system's input device list (`kAudioHardwarePropertyDevices` with input scope). Filter it out when displaying available mics or when `AVAudioEngine` is selecting a default input device. RecordKit fixed this in v0.84.0 ("Filter out aggregate device from available microphone list").

**Production validation:** CATap is used in production by RecordKit (Nonstrict, commercial SDK, default since v0.82.0), Chromium (behind feature flag since 2025), and audiotee (powers talat.app, commercial meeting transcription).

**Reference implementations:** insidegui/AudioCap (490 stars, cleanest CATap pattern), graphaelli/audiotap (documents AudioDeviceStart hang and mic device following).

### D6: System notification for permission loss

**Decision:** When audio capture permission is lost, send a system notification in addition to the menu bar indicator.

**Why:** During a call, the user is focused on the call app and may not notice the menu bar state change. System notifications appear in Notification Center regardless of focus. The notification informs the user that mic is still recording and guides them to re-authorize.

### D7: No Voice Processing (VPIO) - echo handled by post-processing AEC

**Decision:** Do not enable `setVoiceProcessingEnabled(true)` on AVAudioEngine's inputNode. Handle echo cancellation via post-recording DTLN-aec CoreML processing.

**The problem:** Without AEC, the mic track picks up the remote person's voice through speakers. Playing both tracks simultaneously produces audible echo/doubling. The track selector (Both/System/Mic) lets users isolate tracks during playback.

**Why VPIO was rejected:** VPIO hooks into the system audio output path to create an aggregate device for its AEC reference signal. This silences SCStream's display-wide system audio capture (confirmed experimentally), and would similarly conflict with any capture backend that depends on the output path. Independently confirmed by the alona project: "When capturing system audio, voice processing causes audio quality issues."

**Current mitigation:** DTLN-aec CoreML post-processing uses the system audio track (track 0) as the AEC reference to cancel echo from the mic track. Device latency offset compensation (D9) improves AEC quality by reducing the initial misalignment between the reference and mic tracks.

### D8: Silence gap filling for multi-track timeline integrity

**Decision:** Each capture pipeline tracks `nextExpectedTime` (PTS + duration of last written buffer). When an incoming buffer's PTS exceeds the expected time, write zero-filled silence buffers to fill the gap before writing the real buffer. Gap filling is best-effort - if it fails, the real buffer is still written. Never risk the recording for sync accuracy.

**The problem:** AVAssetWriter does not preserve PTS gaps. When a buffer arrives at t=12.5s after the last buffer ended at t=10.0s, the writer concatenates them back-to-back, making the track 2.5s shorter. Over a multi-hour recording with device switches, one track can become seconds shorter than the others, causing growing desync between tracks. Confirmed by Apple behavior, third-party production apps (RecordKit/Nonstrict), and empirical testing with a 2-hour recording where 4 mic device switches caused 8.64s of collapsed gaps.

**Why this affects Blackbox specifically:** Two independent capture pipelines (SCStream system audio, AVAudioEngine mic) can each independently experience gaps. Mic device switches (Bluetooth connect/disconnect, Krisp activation) cause AVAudioEngine tap teardown/reinstall. SCStream remains transparent across output device changes in normal operation, but any stall in the sample handler still shows up as a PTS gap. Any gap in either track makes that track shorter, desynchronizing both tracks in the final M4A.

**Why not just use correct timestamps:** The mic tap already uses `AVAudioTime.hostTime` (wall clock) for PTS, so timestamps correctly reflect the gap. But AVAssetWriter's AAC encoder ignores timestamp discontinuities and concatenates samples. There is no AVAssetWriter property or setting to change this behavior.

**Clock domain alignment:** SCStream `CMSampleBuffer` PTS and AVAudioEngine mic PTS are both on the host time clock (`mach_absolute_time`). Apple documents `AVAudioTime.hostTime` as `mach_absolute_time`. SCStream's sample handler delivers buffers whose PTS derive from the same host clock. `AVAssetWriter` performs no clock normalization - it assumes all inputs share the same timeline, which they do. Cross-correlation of a 2-hour recording confirmed both clocks run at the same rate (0.049s variation over 7233s).

**AAC priming is not a concern:** Each AVAssetWriterInput gets its own AAC encoder with identical 2112-sample priming (Apple TN2258). AVAssetWriter writes per-track edit lists to trim priming on playback. Since all tracks use the same Apple AAC encoder, priming is consistent across tracks and does not cause inter-track offset.

**Implementation constraints:**
- Silence buffers must be written in small chunks (~1024 samples matching normal buffer cadence). One large silent buffer spanning the entire gap causes `kCMSampleBufferError_ArrayTooSmall` (-12737) or crashes the AAC encoder (confirmed by darrarski/macOS-audio-gap-demo and SO reports).
- Silence buffers must use a clean LPCM format description built from scratch (Float32, packed, interleaved, no extensions). Do NOT reuse format descriptions from pipeline buffers - those may include channel layout extensions or non-interleaved flags that don't match the flat zero-filled block buffer, causing `input.append()` to reject or the writer to enter `.failed` state.
- Gap detection threshold: >5ms (240 samples at 48kHz) to avoid false positives from normal PTS jitter.
- Gap filling runs on `audioQueue`, same as all other writer state mutations.
- `nextExpectedTime` is updated BEFORE the `isReadyForMoreMediaData` guard, so dropped buffers don't create false gaps on the next buffer.

**Safety: never risk the recording for sync.**
- If silence `input.append()` returns false, break out of the fill loop and proceed to write the real buffer. Accept partial desync over data loss.
- If `isReadyForMoreMediaData` is false during filling, break immediately - don't block `audioQueue` waiting.
- The real buffer is always attempted regardless of gap fill outcome. Existing error handling in the system audio sample handler catches writer `.failed` state.
- With a clean LPCM ASBD, the risk of silence causing writer failure is essentially zero - it's the same format that `asSampleBuffer()` produces for mic audio.
- Log all gap fills (real-time) and partial fill interruptions for diagnostics. Summarize `gapsFilled` count per pipeline in stop() stats.

**Production validation:** Nonstrict ships the same approach in RecordKit (commercial macOS recording SDK). Their November 2024 blog post describes the same problem (Core Audio gaps during device switches, AVAssetWriter collapsing them) and the same solution (detect via PTS tracking, fill with silent CMSampleBuffers in small chunks).

**Alternatives evaluated and rejected:**
- *Different container/writer:* AVAssetWriter is the only Apple real-time writer for M4A/MOV. No container preserves mid-stream PTS gaps.
- *Separate AVAudioFile (PCM) for mic + post-mux:* Trades real-time problem for post-processing problem. Loses `movieFragmentInterval` crash safety. Same complexity.
- *SCStream `captureMicrophone` (macOS 15+):* Would solve sync (shared `synchronizationClock` within one SCStream), but API is too immature - Apple's own sample code ships broken, `SCRecordingOutput` has corruption bugs with dual audio, zero documentation on device-switch behavior, zero real-world adoption in recording apps. Revisit if stabilized in future macOS versions.
- *`startSession`/`endSession` for gaps:* Sessions are writer-wide, not per-input. Would disrupt all tracks.
- *Post-processing gap repair:* Cannot detect gaps after the fact - AVAssetWriter already collapsed them and rewrote timestamps to be contiguous.
- *Keep AVAudioEngine tap alive through device switch:* Not possible. AVAudioEngine stops and uninitializes itself on config change (`AVAudioEngineConfigurationChangeNotification` fires after the engine is already stopped). The tap-alive gap itself is unavoidable; see D12 for the supplemental listener + watchdog that catches cases the notification misses and route the same debounced teardown/reinstall to heal them.
- *Low-level AUHAL AudioUnit for mic:* Reduces gap duration (~50ms vs ~300ms debounce) but doesn't eliminate it. Still needs silence filling. 200+ lines of C-level CoreAudio code for marginal improvement.
- *AVCaptureSession for mic:* Still a separate pipeline from CATap, same cross-clock issue. No advantage over AVAudioEngine for this problem.

**Scope:** Mic track only. System audio (SCStream) CMSampleBuffers are appended directly to a stereo AAC writer input with no synthesised silence (D11, v0.6.0 parity) - v0.6.0 shipped without system-track gap fill for weeks across Chrome, Zoom, Meet, and FaceTime, and constructing format-matched non-interleaved stereo silence on demand is brittle enough to reintroduce the risk the passthrough just removed. Mic device switches (Bluetooth connect/disconnect, Krisp activation) remain the common source of gaps and are filled as described above.

### D9: Device latency offset compensation for mic-system alignment

**Decision:** At recording start and on each mic device change, query CoreAudio device latency properties for the current input device and apply a constant PTS offset to mic samples. This compensates for the pipeline processing delay difference between the system audio capture path and AVAudioEngine mic audio.

**The problem:** System audio and AVAudioEngine mic audio traverse different processing pipelines with different internal latencies. Even though both ultimately use `mach_absolute_time` for timestamps, the mic track arrives with a different offset than the system audio track. In practice, the mic track appears ~20-70ms ahead of system audio, depending on hardware. Without compensation, this causes audible echo/doubling when playing both tracks.

**History:** D9 was added in v0.7.0 when the CATap backend made the offset large enough to be obviously audible. After reverting to display-wide SCStream in v0.8.0, D9 is kept as-is: the offset it corrects is a mic-side hardware latency, not a capture-backend property, so the fix is backend-agnostic. Validated against the SCStream backend via hardware smoke test and live FaceTime/Chrome recordings - mic-system alignment holds under passthrough.

**How offset is computed:** Query the input device's total latency in frames at recording start using CoreAudio Swift wrappers:

```
Input latency (frames) = device.inputLatency
                       + stream.latency (first input stream)
                       + device.inputSafetyOffset
```

Convert to seconds: `offsetSeconds = inputLatencyFrames / device.nominalSampleRate` (uses actual device sample rate, not hardcoded 48kHz). Apply as a constant PTS shift to all mic samples: `adjustedPTS = originalPTS - offset`. The PTS shift uses `AudioConvertNanosToHostTime` for correct Mach time conversion (timebase ratio is not always 1:1).

**When to re-query:** On `AVAudioEngineConfigurationChange` notification (device switch), query the new device's latency properties and update the offset. The offset changes because different devices have different hardware latencies (e.g., built-in mic ~70ms, AirPods ~30ms, USB mic varies).

**Limitations:** Apple engineers confirmed there is "no way to get accurately timed information from the input relative to the output without a manual calibration process." Even Logic Pro gets this wrong. The queried latencies get within a few ms of correct, which is imperceptible for call recording. For sample-perfect alignment, post-recording cross-correlation would be needed (available via `Scripts/align-and-process.py`).

**Production validation:** RecordKit (Nonstrict) uses a configurable `audioDelay` parameter (v0.51.0) for the same purpose. They added "additional audio delay logging for debugging" (v0.51.1) to help determine the right value per hardware configuration.

**Reference:** CoreAudio latency formula from Apple engineer Dan Klingler (CoreAudio mailing list, July 2017) and sbooth's SO answer verified experimentally on MacBook Pro. Typical values at 48kHz: input = 114 (device) + 2404 (stream) + 40 (safety) = 2558 frames (~53ms), output = 71 + 424 + 11 = 506 frames (~11ms). Note: Klingler's original formula also includes IO buffer size (kAudioDevicePropertyBufferFrameSize, typically 512 frames), which represents the buffer fill time. Our formula omits it because AVAudioEngine's tap delivers at the engine's IO cycle boundary, making the buffer size latency implicit in the timestamp.

### D10: Display-wide SCStream for system audio (supersedes D5 in v0.8.0)

**Decision:** Revert system audio capture from CATap back to a single display-wide `SCStream` (ScreenCaptureKit). This is the same capture strategy as v0.6.0's safety-net stream, stripped of the per-app best-effort stream.

**Why the reversal:** CATap produced three distinct silent-recording bugs in the 5 days after v0.7.0 shipped, all in the same failure class:

1. **Apr 16:** Bluetooth HFP pins aggregate device at 24kHz; IO proc never fires.
2. **Apr 17:** IO proc stops emitting when nothing plays; 18s post-call silence drop.
3. **Apr 20:** Default-output device idle while Chrome Meet routed call audio to non-default output via in-page picker; full-hour mic-only recording.

**Root cause:** CATap's aggregate-device IO proc fires on the main sub-device's hardware output clock. When that clock is idle, pinned, or stalled, the tap has audio to deliver but no ticks to deliver it on. This is structural to the CATap architecture, not fixable with config or watchdog logic - a watchdog restart hits the same idle clock, exhausts the 3-restart/30s budget, and turns 60 min of working-mic recording into ~45s of partial + error.

**Why display-wide SCStream instead:** Its clock comes from the OS-composited mix, decoupled from any specific hardware output device. There is no scenario where an active app is producing audio but SCStream's clock stops ticking. v0.6.0 used display-wide SCStream as the critical backbone for weeks in production with zero silent-recording reports. Empirically bulletproof on the scenarios that break CATap.

**Why D5's arguments no longer apply:**
- **Permission UX:** On macOS 26.1+ (current deployment target), a Screen Recording grant also grants audio capture (see Permissions section). The permission argument for CATap is neutralized.
- **Chrome silence bug:** That was a per-app SCStream bug, not a display-wide bug. Display-wide SCStream captures the composited mix and never had the Chrome silence issue.
- **Latency:** Post-processing AEC doesn't require sub-10ms capture latency. SCStream's handler-queue latency is immaterial for call recording.

**What's preserved from v0.7.0:**
- Actor-based `AudioRecorder` with custom `DispatchSerialQueue` executor.
- `RecordingPipeline` extraction for testability.
- `AudioMonitorDependencies` DI with `TestClock`/`TestRecorderFactory`.
- Hardware smoke test infrastructure (`BlackboxTestMode`, file-based IPC).
- D8 silence gap filling.
- D9 device latency offset compensation.
- Swift 6.2 strict concurrency.

**SCStream configuration (audio-only):** `capturesAudio = true`, `sampleRate = 48000`, `channelCount = 2`, `excludesCurrentProcessAudio = true`, minimal video (`width = 2`, `height = 2`, `minimumFrameInterval` at max timescale) to suppress video pipeline overhead. Filter: `SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])`.

**Error routing:** `SCStreamDelegate.didStopWithError` maps NSError codes to `RecorderFailure` (−3801 → `.permissionDenied`, −3802/−3821 → `.systemStopped`, other → `.other`), feeding the same AudioMonitor restart budget logic used for CATap.

**Non-goals:** No per-app SCStream (v0.6.0 had it as best-effort AEC reference; marginal benefit, Chrome silence history). No new audio-RMS watchdog (SCStream surfaces permission/stop errors via `didStopWithError`).

### D11: Restore v0.6.0 system-audio ingest shape

SCStream CMSampleBuffers are appended directly to a stereo 128 kbps AAC writer input. The v0.7.0/v0.8.0 PCM round-trip + `resampleToMono48k` downmix + re-wrap path is removed on the system track. The old helper (`pcmBuffer(from:)`) assumed interleaved PCM but SCStream on macOS 26 delivers non-interleaved stereo Float32; mis-copying non-interleaved payloads is the suspected root cause of silent FaceTime recordings.

Mic track still resamples/downmixes to mono via `resampleToMono48k` - only the system-track ingest changes. Gap fill (D8), leading silence, and tail padding now apply to the mic track only; v0.6.0 shipped without system-track gap fill for weeks across Chrome, Zoom, Meet, and FaceTime. AEC post-processing is unchanged: the reader pulls track 0 with `AVNumberOfChannelsKey: 1` in its output settings and AVAssetReader auto-downmixes stereo source to mono on read.

File-size trade-off: stereo 128 kbps vs mono 64 kbps means the system track roughly doubles on disk (~29 MB vs ~14 MB for a 30-minute call). Accepted - this is what v0.6.0 shipped with.

### D12: Layered mic recovery - default-input listener + buffer-arrival watchdog

**Decision:** In addition to the existing `AVAudioEngineConfigurationChange` observer, register a CoreAudio `kAudioHardwarePropertyDefaultInputDevice` listener on `kAudioObjectSystemObject` and run a buffer-arrival watchdog on `audioQueue`. All three signals feed the same debounced teardown/reinstall path the notification already drives.

**Why:** `AVAudioEngineConfigurationChange` is reliable for format-changing switches but empirically does not fire on same-format default-input swaps (see Key Architectural Constraints). The watchdog is the universal safety net - agnostic to what CoreAudio tells us - and catches virtual-driver crashes, AirPods A2DP↔HFP in-place stalls, `DeviceIsAlive=false` on a still-default device, Continuity Mic disconnects, and unknown-unknowns. Blackbox's product promise requires self-healing across the device zoo, not just the cases the platform notification covers.

**Why layered instead of single-signal:** The notification gives the fastest recovery when it fires (~300 ms debounce). The default-input listener catches the proven same-format miss with comparable speed. The watchdog catches everything else with a 2 s trip threshold - slower, but the only signal that treats silence itself as the failure mode. Per-device `kAudioDevicePropertyStreamFormat` / `kAudioDevicePropertyDeviceIsAlive` listeners were evaluated and rejected: their coverage is subsumed by the watchdog, and tracking listeners against a moving AudioDeviceID target adds state for no evidence-backed gain.

**Gap handling on healing:** D8's silence fill engages automatically on the PTS discontinuity introduced by any reinstall path - the watchdog's reinstall is indistinguishable from a notification-driven reinstall. D9 latency offset is re-queried for the new device on the same handler. No extra bookkeeping in the listener or watchdog. The mic track ends at the same final time as the system track (tail padding closes any unhealed residual gap on stop).

**Watchdog semantics:** DispatchSourceTimer on `audioQueue`, 1 s cadence. Trips when `mach_absolute_time() - lastMicHostTime > 2 s` while `!stopped` and engine is expected to be running. AVAudioEngine taps deliver buffers every IO cycle regardless of acoustic silence (user-muted pauses keep `lastMicHostTime` advancing), so legitimate quiet does not trigger a false reinstall.

**Idempotency:** Three signal sources can fire for one event. The existing `configChangeGeneration` counter coalesces; redundant calls are cheap no-ops on a stopped engine.

**Observability:** Each restart logs its source (`avaudioengine_notification` / `default_input_listener` / `watchdog_mic_stall`). Log data over time is the basis for deciding whether any source can be dropped, or whether new listeners need adding.

**Lifecycle:** Listener registered in the mic start path and removed in the mic stop path; the `AudioObjectPropertyListenerBlock` reference is stored so deregistration uses the same block (HAL API requirement). Watchdog timer created at mic start, cancelled at mic stop and in `deinit`. Both guard with the `stopped` flag.

### D13: Recorder lifecycle invariant - no zero-byte artifacts, no silent stop

**Decision:** `AudioRecorder` is a four-phase actor (`notStarted` -> `starting` -> `running` -> `stopped`) with a `cancelRequested` flag set synchronously by `stop()`. Buffer-handling sites guard on `phase == .running`; lifecycle sites guard on `phase != .stopped`; in-flight start sites guard on `cancelRequested` via `checkAlive()` after every await. `phase = .running` is set the instant `SCStream.startCapture()` returns (before mic startup) so initial system-audio buffers are accepted on legitimate starts.

**Why:** A tester observed a 5h46m "ghost" recording that wrote a 0-byte M4A and made the Stop menu item silently fail. Root cause: Swift actor reentrancy. `start()` had two await points (`SCShareableContent` ~12 s, `stream.startCapture()`); a `stop()` flipping a single `stopped` flag mid-await let `start()` resume past the await and create a live recorder no caller held a reference to. Every audio buffer hit `guard !stopped`, was dropped, and the writer never finalized. The phase machine + cancellation flag closes that race.

**Cleanup contract:** A recording is either a finalized playable M4A or no on-disk artifact - never zero bytes. Cancellation cleanup uses a take-and-nil pattern (snapshot resources to locals, nil actor fields synchronously, then await teardown on the locals) so a reentrant second caller sees nil fields and is a no-op. Mic-side teardown delegates to `stopMicCapture()` because nilling `defaultInputListenerBlock` / `configChangeObserver` directly leaks the registered observer with the OS. SCStream `stopCapture` races against a 3 s timeout so a hung WindowServer cannot exceed `applicationShouldTerminate`'s 8 s budget.

**Pipeline self-clean:** `RecordingPipeline.start()` wraps the post-`createDirectory` body in a do/catch that removes the recording directory on any partial-init throw (`metadata.save`, `AVAssetWriter` init, `startWriting`). Combined with the cancellation cleanup, no failure path leaves an orphan dir or zero-byte file in `~/Library/Application Support/Blackbox/Recordings/`.

**Monitor cooperation:** `AudioMonitor` tracks the in-flight `start()` Task per recorder kind (`autoStartTask`, `manualStartTask`). The Task body uses an identity guard (`autoRecorder === recorder`) before promoting state, so a stop-during-startup race lands silently in the catch path - no error toast on legit user-initiated stop. `RecorderError.cancelled` and lost-race conditions are matched as silent. `stopMonitoring` snapshots both start tasks before awaiting recorder stops, then awaits the Task bodies so the 8 s termination budget covers the full unwind.

**Suppression:** After a user-initiated stop (manual stop, force-stop on auto), `AudioMonitor` records the resolved parent bundle ID in `suppressedBundleID: String?`. `evaluateCallState` filters that bundle out of the eligible-caller set; suppression clears the first poll the bundle disappears from the full caller set. Grace-expiry stops do not suppress - the bundle has already left, and re-detection should be free to record again. Single-bundle by design: covers the reported Chrome case; multi-bundle suppression is speculative and out of scope.

### D14: Auto-transcription - app-level coordinator with a resumable job sidecar

**Decision:** Transcription is owned by `TranscriptionCoordinator`, an `@Observable` MainActor object created in `BlackboxApp` and injected into the window's environment. It runs one job at a time and persists each job's stage to a `transcription-job.json` sidecar inside the recording directory. `TranscriptionService` exposes stage-level calls (`upload` -> `createTranscription` -> `awaitCompletion` -> `fetchTranscript` -> `deleteRemote`) behind the `TranscriptionServicing` protocol; the coordinator drives the state machine.

**Why:** Transcription previously lived in `RecordingDetailView` as `@State`, with `.onDisappear` cancelling the task - closing the window killed the job, and an automatic trigger had nowhere to live. Splitting the service into stages is what makes the sidecar useful: a job interrupted after upload resumes by polling the existing `transcriptionId` instead of paying for a second upload.

**Trigger:** `AudioMonitorDependencies.onRecordingSaved` fires for every `stop()` that returns a URL - the two clean stop paths, both recorder-failure paths, and the quit path - so a recording ended by a permission revocation or by quitting is transcribed like any other. The monitor itself stays independent: the default hook is a no-op, and `BlackboxApp` is the only place that wires it to the coordinator. Auto-transcription additionally requires the `autoTranscribe` setting (default off) and a Soniox key in the Keychain; the manual button in the detail view routes through the same coordinator and ignores the setting.

**Consent is re-checked at every point where money can be spent, not just at trigger.** At quit the monitor reports saved recordings *before* clearing `isRecording`, so `pump()` defers behind the recording gate and the process exits having written only a sidecar. (Not quite universally: a quit landing between a recorder being assigned and its start Task setting `isRecording` would not defer. The conclusion survives - resume is the normal path either way.) That makes resume the normal path for quit-time recordings, not an edge case. The rule lives in one predicate, `isConsentWithdrawn(for:)`, and is applied at four points: at resume, so a withdrawn job never joins the queue, again on entry to `run()`, again on every pass of the job loop, and again immediately before `createTranscription` - the call that actually bills - because `upload` sits between the two and re-encodes and transmits the whole recording, which is minutes for a long call. The waits are long enough to matter: the recording gate re-arms every 30s for as long as any call is live, a job ahead in the queue can burn its own 30-minute poll ceiling plus 30s/2m/8m of backoff, and an offline job waits 60s up to 60 times. Checking only at enqueue, or only once on entry, would let a job that has been sleeping upload and bill after consent was withdrawn. The cutoff is `transcriptionId`, not `fileId`: once Soniox has been billed the money is spent and finishing beats discarding a paid-for transcript, but a job that has only *uploaded* is dropped and its audio deleted, since nothing has been charged yet and a delete can usually be dispatched - "usually" because that needs an API key, which is what the cleanup block below is about. Manual jobs are exempt at every point; the user asked for them explicitly, and `enqueue` downgrades the `isAutomatic` flag on an existing sidecar so a queued automatic job that the user then asks for by hand is not later mistaken for an automatic one. The downgrade always reaches the sidecar, including an active job's, but `run` holds its own copy of the record and writes it back, so an active job keeps the flag it started with until it finishes. Nothing reaches that state through the UI, which offers Cancel rather than Transcribe while a job runs.

**Automatic uploads have a duration floor** (`minimumAutomaticSeconds`, 3s). `onRecordingSaved` fires for every `stop()` that returns a URL, and an automatic job spends the user's money with no prompt. What it catches in practice is an early manual stop and a recorder that died at startup; it does *not* catch a false-positive call detection, because a detection-driven stop waits out the grace period, which is clamped to a 5s minimum on top of the 3s poll interval, so such a recording is never shorter than about 8s. The floor is checked in `run()` rather than in `recordingFinished`, so reading the asset duration stays off the quit path. It fails closed: a container that will not open is exactly what a recorder that died on startup leaves behind, so an unreadable duration counts as below the floor rather than being waved through. Two exemptions: manual jobs, and any job already holding a `transcriptionId`, which has been billed and is finished for the same reason the consent cutoff uses that field.

**Which audio file:** `audio-processed.m4a` when echo cancellation has been run, otherwise `audio.m4a`, resolved at job run time rather than enqueue time. `RecordingStore.audioURL(in:)` holds the rule and resolving late lets a resumed job pick up an AEC pass that finished in between, but transcription is its only caller. Playback does not share it - there the processed file is a user toggle - the storage stats deliberately sum both files, and the recordings list re-derives the same choice inline because it has to stat both files for their sizes anyway.

**Failure policy:** Offline is a wait, not a failure - it retries every 60s without consuming an attempt, bounded by its own count (`maxOfflineWaits`, 60) rather than by the retry budget. Transient failures retry three times with 30s/2m/8m backoff: 5xx, 429, a 409 `.notReady`, `pollTimeout`, and six `URLError` codes covering dropped, timed-out and unresolvable connections. Everything else is terminal: the sidecar is kept with `lastError` set so the recording row shows the failure and the detail view offers a retry, and launch resume deliberately surfaces those jobs instead of re-running them. Running out of *offline waits* leaves the sidecar resumable rather than terminal, because the last thing seen was a missing network rather than a fault, but the status is surfaced as an error so the user can see that a job is parked and that its audio may already be on Soniox. It is not the only exit that is neither success nor failure - every `drop` path and the missing-key guard are others - and it is one of two that keep a runnable job on disk, the other being the missing-key guard described below. There is no separate pass counter - `job.attempts` persists across runs and `.retry` is only chosen while it is under `maxAttempts`, so the retry path is self-bounding. A transcript that cannot be written to disk is reported as a terminal failure; note this loses the transcript, because `fail` also deletes the remote copy when it can, so the offered retry normally re-uploads and re-bills from scratch. When the delete could not be dispatched the ids are kept and the retry resumes from them instead. That is the accepted cost of not carrying a paid-for result around in memory.

**Nothing is left on Soniox that this client can still name.** Every path that destroys a job's local record goes through `discardRemote` first - success, terminal failure, cancellation, consent withdrawal, the duration floor, the recording-went-away drop, and the case where the directory has no audio file left to send. Success, abandonment and cancellation all retire the local record through `releaseRemoteRecord(_:in:)`, and terminal failure through `fail(_:in:message:)`. Both obey the same rule: **the ids are only destroyed once something is actually on its way to delete them.** `discardRemote` returns false when it cannot even dispatch, which happens when the user has cleared or rotated the API key while a job held artifacts. Without that rule, clearing the key and then cancelling would erase the only ids naming audio sitting on Soniox, with nothing in the log.

What the two funnels do with a deferred cleanup differs, because they leave different things behind. `releaseRemoteRecord` has no job left to represent, so it keeps a delete-only record marked `awaitingRemoteDelete`; resume retries the delete and never re-runs it. `transcribe` is the only other reader: when the job was abandoned the recording reads as untranscribed, so the detail view offers a Transcribe button, and taking it discards the leftovers and starts from nothing rather than polling ids it is deleting. When the job *succeeded* and only the cleanup was deferred, the transcript is on disk, no button is offered, and resume is the sole path back to that record. `fail` has a failure the detail view must keep offering a retry for, so it keeps the record with `lastError` and simply does not clear the ids; resume retries the delete for any failed record that still carries them. The two states never coexist, which is what keeps resume's branch order from mattering.

The missing-key guard at the top of `run()` is a third exit that deliberately touches neither: it leaves the sidecar intact so a later launch with a key restored can resume or clean up. A terminal failure clears `fileId`/`transcriptionId` from the sidecar so a retry starts clean, but only when the delete was dispatched - see above. Cancelling a *queued* job loads its sidecar first - dropping it without that would strand audio on Soniox with nothing left on disk that could name it.

Cleanup is deliberately fire-and-forget (`discardRemote` spawns an unstructured `Task`), including on the success path. Awaiting it inside the job's own task looks tidier but is wrong twice over: the task is cancellable, so a cancel or a quit landing between the sidecar removal and the DELETEs kills the cleanup with the ids already gone from disk, and it holds the queue across two round trips before the next job can start. `deleteRemote` logs a non-2xx (404 excepted, which means it is already gone) rather than swallowing it - a silent miss is the one outcome that must not be invisible. It is not the last line of defence - a delete that could not be dispatched at all keeps its record for the next launch - but it is the only signal for one that was dispatched and failed.

Seven residuals remain.

*Idempotency* - Soniox has no idempotency key. A request that fails after the multipart body was fully transmitted but before the response arrives can leave a file whose id was never learned. A process death between a committed remote call and the `job.save` that records its id makes resume re-issue that stage: a second upload, or a second billed transcription with the first orphaned.

*Fire-and-forget delete* - the ids are released when a DELETE is dispatched, not when it is confirmed. A DELETE that fails on the wire (a 5xx during the same outage that caused the job to fail terminally, so correlated rather than independent) leaves the artifact behind. So does a quit in the window between the local record being removed and the spawned delete completing.

*A deferred cleanup that never gets its second chance* - a user who never restores an API key leaves both the delete-only record and the remote audio in place, because `resumePendingJobs` returns early without a key. And deleting a recording whose cleanup was deferred loses that record with the directory: for an inactive job the record is written correctly and then moved to the Trash along with everything else, and for an active one it is written into a directory `trashItem` has already moved. Same outcome either way.

A seventh sits on the read side: a record that exists but will not decode is skipped on every launch, so anything it uploaded stays on Soniox. It is now logged rather than silent, and `.atomic` writes plus a decoder that treats every key as optional make it hard to produce, but nothing recovers from it automatically.

The offline give-up path also leaves audio in place, but that one is a choice rather than a leak: the record is kept so the next launch can resume the job rather than pay to upload it again.

Most are bounded; the never-restored-key case is not, since nothing else will ever look at that record. Every *transcription* carries `client_reference_id` set to the recording directory name, so a stray transcription stays identifiable in the Soniox console - a stray uploaded *file* does not, because the upload carries only a multipart filename, which for a mixed recording is a UUID and otherwise a constant. Closing the idempotency pair needs a reconciliation query against `client_reference_id` at resume; closing the fire-and-forget pair needs the delete to confirm before the ids are released, which means carrying the record until a DELETE returns 2xx or 404 rather than until it is dispatched. Both are follow-ups rather than part of this change.

**Error mapping follows the published contract, not inference.** Soniox answers every non-2xx with `{status_code, error_type, message, validation_errors, request_id}`; `request_id` is logged because it is what their support asks for. Status handling keys on the code alone, never on `error_type`: **409** (which Soniox documents as `transcription_invalid_state`) is `.notReady` and retryable - polling and fetching are separate calls, so a job that completes between them answers 409 for a moment, and treating that as terminal would kill a job that was about to succeed. **402** is `.balanceExhausted` and terminal, because retrying a dead balance only wastes time. **429** and **5xx** are `.serverError` and retryable. Everything else is terminal. The transcription status enum is `queued | processing | completed | error` - note there is no `transcribing`, which an earlier revision branched on and therefore never matched.

**The model id is configuration, not a constant** (`sonioxModel`, default `stt-async-v5`), so a model retirement does not need an app release. `stt-async-v4` was an alias for v5 and was retired on 2026-06-30.

**Contract tests over a loopback stub.** `Tests/SonioxContractTests.swift` runs the real client against a BSD-socket HTTP server speaking Soniox's documented wire format - covering the request bodies, multipart integrity, the transcript token schema, and the 402/409/429/5xx paths that a hand-written fake cannot produce. Plain sockets rather than `NWListener`, which fails to bind with EINVAL on macOS 26, and a real socket rather than a `URLProtocol` mock, which would stub out the streamed multipart upload that is the most fragile part. The tests are free, offline and deterministic, so they run in `make check`; they encode the published schema, which is the one thing they cannot verify for themselves.

**Test mode is defended at three depths, and the redundancy is deliberate.** A smoke run records genuine audio on a developer's machine, so the cost of a gap here is their private call audio reaching a third party - and each layer covers a different way the others can fail. *Intent:* `--ui-test-mode` does not wire `onRecordingSaved` at all, so the trigger is absent. *Configuration:* `BlackboxSmokeClient` launches the app with `-autoTranscribe NO`, which lands in `NSArgumentDomain` and outranks every persisted domain, so the setting reads false even if something re-wires the hook; transcription is the only setting the app under test still reads from the real defaults, the rest being replaced wholesale by the test-mode branch of `loadSettings`. *Enforcement:* `TranscriptionService.assertEgressAllowed` refuses to build any client pointed at the live host under test mode, so egress to the live host is impossible even if both of the above fail - nothing in production supplies any other URL. It is a `precondition` rather than an `assert` because `make bundle` builds release, which is what the suite launches, and it guards `verifyAPIKey` separately because that is `static` and never passes through `init`.

Collapsing these to one would be a mistake of the kind this feature has already made once: the first fix here gated the save directory but not the trigger, which is exactly a single layer failing alone. The hook reads the real `autoTranscribe` setting and the real Keychain key, and the smoke suite records genuine audio on a developer's machine, so leaving it wired means `make test` uploads the three recordings the hardware suite makes - roughly 4s, 6s and 12s, all over the floor - and bills that developer. `Dependencies.saveDirectory` also honours `BlackboxTestMode.saveDirectoryOverride`, though nothing reaches it in the current code: its only reader is `resumePendingJobs()`, which sits after the test-mode early return in `BlackboxApp`. It is kept because the alternative - a coordinator that silently scans the user's real recordings folder if that ordering ever changes - is worse than dead code.

**Quit:** Nothing on this path joins `applicationShouldTerminate`'s 8s budget in the sense of being awaited. `enqueue` does write its sidecar synchronously on the main thread inside `stopMonitoring`, so a save directory on a stalled network share would block there - but the `AVAssetWriter` finalization already on that path writes vastly more to the same directory, so the marginal exposure from a 100-byte sidecar is not what would fail first. An in-flight job dies with the process and is picked up by `resumePendingJobs()` on the next launch, which also sweeps the mix and upload scratch files a killed job leaves in the temp directory - each is the full size of a recording.

**Backpressure:** A job will not start while a recording is active (`isRecordingActive`, late-bound because the monitor and the coordinator are constructed together). Mixing re-encodes the whole file, so a job must not begin competing with a live call for CPU or disk. The gate is read once in `pump()`, not continuously: a job already running when a call starts keeps going.

**Consent:** Audio leaves the machine on every recording over the duration floor once this is on, so the setting is opt-in, defaults off, is disabled without an API key, and says plainly what it does - including that the audio is deleted from Soniox once the transcript is back.
