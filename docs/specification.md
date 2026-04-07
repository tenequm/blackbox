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
│  │  CATap (CoreAudio Tap) │       │     AVAudioEngine            │  │
│  │                        │       │                              │  │
│  │  Global system audio   │       │  Mic via inputNode tap       │  │
│  │  via aggregate device  │       │  Follows system default      │  │
│  │  Excludes own PID      │       │                              │  │
│  │  Drift compensation on │       │  PTS offset-compensated      │  │
│  │                        │       │  via device latency query    │  │
│  └───────────┬────────────┘       └──────────────┬───────────────┘  │
│              │                                   │                  │
│              ▼                                   ▼                  │
│         AudioBufferList                    CMSampleBuffer           │
│         (IO proc callback)                 (from PCM + hostTime     │
│              │                              - latency offset)       │
│              ▼                                   │                  │
│         CMSampleBuffer                           │                  │
│         (manual conversion)                      │                  │
│              │                                   │                  │
└──────────────┼───────────────────────────────────┼──────────────────┘
               │                                   │
               ▼                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     GAP DETECTION & FILL                            │
│                                                                     │
│  Per-pipeline: track nextExpectedTime from PTS + duration           │
│  If incoming PTS > expected → write zero-filled silence buffers     │
│  Ensures AVAssetWriter receives continuous timeline (no gaps)       │
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

## Key Architectural Constraints

These are non-obvious constraints discovered during implementation that future changes must respect.

- **AVAssetWriterInput format is immutable.** The internal encoder configures from the first appended buffer's format description. Mid-stream format changes cause `append()` to fail and the writer to enter `.failed` state, losing both tracks. This is why the mic tap must reinstall with the original format on device change.

- **AVAssetWriter collapses PTS gaps.** When audio buffers have a timestamp discontinuity (gap between last buffer's end and next buffer's start), the writer concatenates samples back-to-back, making the track shorter. Gaps must be filled with explicit zero-filled silence buffers to preserve timeline integrity. No AVAssetWriter setting changes this behavior. The writer also performs no clock domain normalization - it assumes all inputs share the same timeline.

- **CATap and AVAudioEngine use different clock domains.** CATap's aggregate device runs on the system output device's clock. AVAudioEngine's mic runs on the input device's clock. Both map to `mach_absolute_time` (host time) but the underlying hardware clocks can drift at ~50 PPM. For a 1-hour recording this is ~180ms worst case. Drift compensation (`kAudioSubTapDriftCompensationKey`) handles system-audio-internal drift, but mic-vs-system drift requires device latency offset compensation (see D9).

- **CATap requires an aggregate device.** `AudioHardwareCreateProcessTap` returns a tap ID that must be added to an aggregate device via `kAudioAggregateDeviceTapListKey`. Audio flows through the aggregate device's IO proc callback as interleaved Float32 `AudioBufferList`, not `CMSampleBuffer`. Manual conversion is required for AVAssetWriter.

- **AudioDeviceStart hang.** Starting a physical input device (mic) via `AudioDeviceCreateIOProcID` while a CATap aggregate device is already running blocks the calling thread indefinitely. Workaround: stop aggregate device, start mic, restart aggregate device. Documented in graphaelli/audiotap.

- **CoreAudio per-process APIs require macOS 14.2+.** `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`. CATap (`AudioHardwareCreateProcessTap`) also requires macOS 14.2+.

- **CATapDescription is ObjC-only.** The `CATapDescription` class has no Swift equivalent. Requires an ObjC bridging file to create and configure tap descriptions from Swift.

---

## Permissions

Two TCC permissions required:

- **System Audio Recording** - for CATap system audio capture. Requires `NSAudioCaptureUsageDescription` in Info.plist. One-click grant in System Settings (no app restart required). On macOS 26+, an existing Screen Recording permission also grants this access.
- **Microphone** - for AVAudioEngine mic capture. Requires `NSMicrophoneUsageDescription` in Info.plist. If denied, system audio still records.

---

## Decision Log

Architectural decisions with reasoning and alternatives considered.

### D1: AVAudioEngine for mic instead of SCStream .microphone

**Decision:** Use AVAudioEngine tap on inputNode for mic capture. Set `captureMicrophone = false` on SCStream.

**Alternatives considered:**
- **SCStream `.microphone`** (previous implementation): requires manual device following via CoreAudio listener + `updateConfiguration()`. On failure, recording splits into separate files. Tied to SCStream lifecycle.
- **AVCaptureSession + AVCaptureAudioDataOutput**: gives CMSampleBuffer natively (no conversion), structured interruption notifications. But requires manual device switching similar to the SCStream approach - doesn't solve the core problem.

**Why AVAudioEngine wins:** Automatic device following via inputNode. One `AVAudioEngineConfigurationChange` notification handler replaces ~140 lines of CoreAudio listener management. Device switches cause a sub-second gap in the same file instead of a recording split. Independent from SCStream - mic survives SCStream death.

**Device switch gap is unavoidable.** When `AVAudioEngineConfigurationChange` fires, the engine has already stopped itself internally. The tap must be removed and reinstalled with the new device's format. This is a platform limitation - the engine cannot survive a sample rate or channel count change without a restart. The 300ms debounce (for Krisp's rapid-fire config changes) dominates the gap duration; the actual reinstall takes <10ms. See D8 for how these gaps are filled with silence to prevent track desync.

**Tradeoff accepted:** ~30 lines of AVAudioPCMBuffer-to-CMSampleBuffer conversion boilerplate. Timestamps use `AVAudioTime.hostTime` (`mach_absolute_time`, wall clock) converted via `CMClockMakeHostTimeFromSystemUnits`, then adjusted by the device latency offset (D9) for alignment with CATap system audio.

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

### D5: CATap for system audio (replaces dual SCStream)

**Decision:** Use CoreAudio Process Tap (`AudioHardwareCreateProcessTap`) via an aggregate device for all system audio capture. Replaces the previous dual-SCStream architecture (display-wide + per-app).

**Previous implementation:** Two SCStream instances - display-wide (critical) + per-app (best-effort) writing to 2-3 track M4A. Per-app track existed to provide a cleaner AEC reference, but was unreliable (Chrome/WebRTC silence bug) and added complexity without real-world benefit.

**Why CATap over SCStream:**
- **Better permission model.** `NSAudioCaptureUsageDescription` grants audio-only permission with a one-click grant. SCStream required Screen Recording permission (broad, confusing for users, requires app restart, subject to macOS 15+ monthly re-auth). RecordKit (Nonstrict) made CATap their default backend in v0.82.0 for this reason.
- **No Chrome/WebRTC silence bug.** CATap captures at the HAL level, below any private audio routing that caused per-app SCStream to deliver silence for Chrome/WebRTC apps.
- **Lower latency.** IO proc callback runs on a real-time thread, delivering audio with less buffering than SCStream's sample handler queue.
- **Built-in drift compensation.** `kAudioSubTapDriftCompensationKey: true` on the aggregate device tap list enables CoreAudio's hardware-level clock synchronization for the system audio tap.
- **Simpler pipeline.** One capture stream instead of two SCStreams. Fixed 2-track output (system + mic) instead of variable 2-3 tracks.

**Setup sequence:**
1. Translate own PID to AudioObjectID via `kAudioHardwarePropertyTranslatePIDToProcessObject`
2. Create `CATapDescription(stereoGlobalTapButExcludeProcesses:)` excluding own PID
3. Call `AudioHardwareCreateProcessTap` to get tap ID
4. Create private aggregate device via `AudioHardwareCreateAggregateDevice` with tap in `kAudioAggregateDeviceTapListKey` and `kAudioSubTapDriftCompensationKey: true`
5. Create IO proc via `AudioDeviceCreateIOProcIDWithBlock` on the aggregate device
6. Start with `AudioDeviceStart` (must respect ordering constraint - see constraints section)

**IO proc callback:** Receives interleaved Float32 `AudioBufferList` on a real-time thread. Must be RT-safe (no allocations, no ObjC messaging, no locks without priority donation). Convert to `CMSampleBuffer` and dispatch to `audioQueue` for writing.

**Output device change:** When the system default output device changes, the tap's aggregate device must be torn down and rebuilt. This causes a gap in system audio (~0.5-1.5s), handled by silence gap filling (D8). Listen for `kAudioHardwarePropertyDefaultOutputDevice` changes.

**Track layout (fixed at writer setup):**
- Track 0: system audio (2ch stereo)
- Track 1: mic audio (when mic enabled, 1ch mono)

**Production validation:** CATap is used in production by RecordKit (Nonstrict, commercial SDK, default since v0.82.0), Chromium (behind feature flag since 2025), and audiotee (powers talat.app, commercial meeting transcription).

**Reference implementations:** insidegui/AudioCap (490 stars, cleanest CATap pattern), graphaelli/audiotap (documents AudioDeviceStart hang and mic device following).

### D6: System notification for permission loss

**Decision:** When audio capture permission is lost, send a system notification in addition to the menu bar indicator.

**Why:** During a call, the user is focused on the call app and may not notice the menu bar state change. System notifications appear in Notification Center regardless of focus. The notification informs the user that mic is still recording and guides them to re-authorize.

### D7: No Voice Processing (VPIO) - echo handled by post-processing AEC

**Decision:** Do not enable `setVoiceProcessingEnabled(true)` on AVAudioEngine's inputNode. Handle echo cancellation via post-recording DTLN-aec CoreML processing.

**The problem:** Without AEC, the mic track picks up the remote person's voice through speakers. Playing both tracks simultaneously produces audible echo/doubling. The track selector (Both/System/Mic) lets users isolate tracks during playback.

**Why VPIO was rejected:** VPIO hooks into the system audio output path to create an aggregate device for its AEC reference signal. This conflicts with system audio capture - tested and confirmed with SCStream, and the conflict likely extends to CATap since both tap the same output path. The alona project independently confirmed: "When capturing system audio, voice processing causes audio quality issues."

**Current mitigation:** DTLN-aec CoreML post-processing uses the system audio track (track 0) as the AEC reference to cancel echo from the mic track. Device latency offset compensation (D9) improves AEC quality by reducing the initial misalignment between the reference and mic tracks.

### D8: Silence gap filling for multi-track timeline integrity

**Decision:** Each capture pipeline tracks `nextExpectedTime` (PTS + duration of last written buffer). When an incoming buffer's PTS exceeds the expected time, write zero-filled silence buffers to fill the gap before writing the real buffer. Gap filling is best-effort - if it fails, the real buffer is still written. Never risk the recording for sync accuracy.

**The problem:** AVAssetWriter does not preserve PTS gaps. When a buffer arrives at t=12.5s after the last buffer ended at t=10.0s, the writer concatenates them back-to-back, making the track 2.5s shorter. Over a multi-hour recording with device switches, one track can become seconds shorter than the others, causing growing desync between tracks. Confirmed by Apple behavior, third-party production apps (RecordKit/Nonstrict), and empirical testing with a 2-hour recording where 4 mic device switches caused 8.64s of collapsed gaps.

**Why this affects Blackbox specifically:** Two independent capture pipelines (CATap system audio, AVAudioEngine mic) can each independently experience gaps. Mic device switches (Bluetooth connect/disconnect, Krisp activation) cause AVAudioEngine tap teardown/reinstall. CATap aggregate device rebuilds on output device change create system audio gaps. Any gap in either track makes that track shorter, desynchronizing both tracks in the final M4A.

**Why not just use correct timestamps:** The mic tap already uses `AVAudioTime.hostTime` (wall clock) for PTS, so timestamps correctly reflect the gap. But AVAssetWriter's AAC encoder ignores timestamp discontinuities and concatenates samples. There is no AVAssetWriter property or setting to change this behavior.

**Clock domain alignment:** SCStream PTS and AVAudioEngine mic PTS are both on the host time clock (`mach_absolute_time`). Apple documents `AVAudioTime.hostTime` as `mach_absolute_time`. SCStream's `synchronizationClock` is the host clock in practice (confirmed by Nonstrict/RecordKit using `CMClock.hostTimeClock.time` for session start). `AVAssetWriter` performs no clock normalization - it assumes all inputs share the same timeline, which they do. Cross-correlation of a 2-hour recording confirmed both clocks run at the same rate (0.049s variation over 7233s).

**AAC priming is not a concern:** Each AVAssetWriterInput gets its own AAC encoder with identical 2112-sample priming (Apple TN2258). AVAssetWriter writes per-track edit lists to trim priming on playback. Since all tracks use the same Apple AAC encoder, priming is consistent across tracks and does not cause inter-track offset.

**Implementation constraints:**
- Silence buffers must be written in small chunks (~1024 samples matching normal buffer cadence). One large silent buffer spanning the entire gap causes `kCMSampleBufferError_ArrayTooSmall` (-12737) or crashes the AAC encoder (confirmed by darrarski/macOS-audio-gap-demo and SO reports).
- Silence buffers must use a clean LPCM format description built from scratch (Float32, packed, interleaved, no extensions). Do NOT reuse the format description captured from SCStream or AVAudioEngine buffers - those may include channel layout extensions or non-interleaved flags that don't match the flat zero-filled block buffer, causing `input.append()` to reject or the writer to enter `.failed` state.
- Gap detection threshold: >10ms (480 samples at 48kHz) to avoid false positives from normal PTS jitter.
- Gap filling runs on `audioQueue`, same as all other writer state mutations.
- `nextExpectedTime` is updated BEFORE the `isReadyForMoreMediaData` guard, so dropped buffers don't create false gaps on the next buffer.

**Safety: never risk the recording for sync.**
- If silence `input.append()` returns false, break out of the fill loop and proceed to write the real buffer. Accept partial desync over data loss.
- If `isReadyForMoreMediaData` is false during filling, break immediately - don't block `audioQueue` waiting.
- The real buffer is always attempted regardless of gap fill outcome. Existing error handling in `handleDisplaySample` catches writer `.failed` state.
- With a clean LPCM ASBD, the risk of silence causing writer failure is essentially zero - it's the same format that `asSampleBuffer()` produces for mic audio.
- Log all gap fills (real-time) and partial fill interruptions for diagnostics. Summarize `gapsFilled` count per pipeline in stop() stats.

**Production validation:** Nonstrict ships the same approach in RecordKit (commercial macOS recording SDK). Their November 2024 blog post describes the same problem (Core Audio gaps during device switches, AVAssetWriter collapsing them) and the same solution (detect via PTS tracking, fill with silent CMSampleBuffers in small chunks).

**Alternatives evaluated and rejected:**
- *Different container/writer:* AVAssetWriter is the only Apple real-time writer for M4A/MOV. No container preserves mid-stream PTS gaps.
- *Separate AVAudioFile (PCM) for mic + post-mux:* Trades real-time problem for post-processing problem. Loses `movieFragmentInterval` crash safety. Same complexity.
- *SCStream `captureMicrophone` (macOS 15+):* Would solve sync (shared `synchronizationClock` within one SCStream), but API is too immature - Apple's own sample code ships broken, `SCRecordingOutput` has corruption bugs with dual audio, zero documentation on device-switch behavior, zero real-world adoption in recording apps. Revisit if stabilized in future macOS versions.
- *`startSession`/`endSession` for gaps:* Sessions are writer-wide, not per-input. Would disrupt all tracks.
- *Post-processing gap repair:* Cannot detect gaps after the fact - AVAssetWriter already collapsed them and rewrote timestamps to be contiguous.
- *Keep AVAudioEngine tap alive through device switch:* Not possible. AVAudioEngine stops and uninitializes itself on config change (`AVAudioEngineConfigurationChangeNotification` fires after the engine is already stopped). Platform limitation, no workaround.
- *Low-level AUHAL AudioUnit for mic:* Reduces gap duration (~50ms vs ~300ms debounce) but doesn't eliminate it. Still needs silence filling. 200+ lines of C-level CoreAudio code for marginal improvement.
- *AVCaptureSession for mic:* Still a separate pipeline from SCStream, same cross-clock issue. No advantage over AVAudioEngine for this problem.

**Scope:** Both pipelines (system audio, mic). Mic device switches are the most common source of gaps. CATap aggregate device rebuilds on output device change can gap the system audio pipeline.

### D9: Device latency offset compensation for mic-system alignment

**Decision:** At recording start and on each mic device change, query CoreAudio device latency properties for the current input device and apply a constant PTS offset to mic samples. This compensates for the pipeline processing delay difference between CATap system audio and AVAudioEngine mic audio.

**The problem:** CATap system audio and AVAudioEngine mic audio traverse different processing pipelines with different internal latencies. Even though both ultimately use `mach_absolute_time` for timestamps, the mic track arrives with a different offset than the system audio track. In practice, the mic track appears ~20-70ms ahead of system audio, depending on hardware. Without compensation, this causes audible echo/doubling when playing both tracks.

**Why this wasn't a problem before (but was):** The previous SCStream architecture had the same offset issue, but it was masked by SCStream's higher internal buffering latency which happened to partially cancel out the mic's hardware latency. With CATap's lower-latency IO proc delivery, the offset is more pronounced and consistent.

**How offset is computed:** Query the input device's total latency in frames at recording start:

```
Input latency (frames) = kAudioDevicePropertyLatency (input scope)
                       + kAudioStreamPropertyLatency (input scope)
                       + kAudioDevicePropertySafetyOffset (input scope)
```

Convert to seconds: `offsetSeconds = inputLatencyFrames / sampleRate`. Apply as a constant PTS shift to all mic samples: `adjustedPTS = originalPTS - offset`.

**When to re-query:** On `AVAudioEngineConfigurationChange` notification (device switch), query the new device's latency properties and update the offset. The offset changes because different devices have different hardware latencies (e.g., built-in mic ~70ms, AirPods ~30ms, USB mic varies).

**Limitations:** Apple engineers confirmed there is "no way to get accurately timed information from the input relative to the output without a manual calibration process." Even Logic Pro gets this wrong. The queried latencies get within a few ms of correct, which is imperceptible for call recording. For sample-perfect alignment, post-recording cross-correlation would be needed (available via `Scripts/align-and-process.py`).

**Production validation:** RecordKit (Nonstrict) uses a configurable `audioDelay` parameter (v0.51.0) for the same purpose. They added "additional audio delay logging for debugging" (v0.51.1) to help determine the right value per hardware configuration.

**Reference:** CoreAudio latency formula from Apple engineer Dan Klingler (CoreAudio mailing list, July 2017) and sbooth's SO answer verified experimentally on MacBook Pro. Typical values at 48kHz: input = 114 + 2404 + 40 + 512 = 3070 frames (~64ms), output = 71 + 424 + 11 + 512 = 1018 frames (~21ms).
