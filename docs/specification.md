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
│    Filter out: own PID, ScreenCaptureKit helpers                    │
│    If found → call detected → start recording                      │
│    If none  → grace period  → stop recording                       │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        CAPTURE                                      │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │  SCStream #1  │  │  SCStream #2  │  │     AVAudioEngine        │  │
│  │               │  │               │  │                          │  │
│  │  Display-wide │  │  Per-app      │  │  Mic via inputNode tap   │  │
│  │  (critical)   │  │  (best-effort)│  │  Follows system default  │  │
│  │  Always runs  │  │  When single  │  │                          │  │
│  │               │  │  caller known │  │                          │  │
│  └───────┬───────┘  └───────┬───────┘  └────────────┬─────────────┘  │
│          │                  │                        │               │
│          ▼                  ▼                        ▼               │
│     CMSampleBuffer    CMSampleBuffer          CMSampleBuffer        │
│     (native)          (native)                (from PCM + hostTime) │
│          │                  │                        │               │
└──────────┼──────────────────┼────────────────────────┼───────────────┘
           │                  │                        │
           ▼                  ▼                        ▼
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
│  AVAssetWriter → 2 or 3 track M4A (AAC, 48kHz)                     │
│    Track 0: display-wide audio (always, 2ch 128kbps)                │
│    Track 1: per-app audio (when single caller, 2ch 128kbps)         │
│    Track N: mic audio (when mic enabled, 1ch 64kbps)                │
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

- **SCStream and AVAudioEngine share the host time clock.** `AVAudioTime.hostTime` is documented as `mach_absolute_time`. SCStream's `synchronizationClock` is the host clock in practice. Timestamps from both pipelines are directly comparable and can be fed to the same AVAssetWriter session without clock conversion.

- **SCStream requires a `.screen` output** even for audio-only capture. Minimum video config (2x2, max frame interval) minimizes overhead.

- **SCRecordingOutput stops on config update.** Confirmed in `SCStream.h` header: "In case client update the stream configuration during recording, recording will be stopped as well." Also lacks crash safety (no movieFragmentInterval). Not viable for our use case.

- **CoreAudio per-process APIs require macOS 14.2+.** `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`.

- **macOS 15+ monthly re-authorization.** Screen Recording permission can be revoked at any time. SCStream dies with error -3801. AVAudioEngine mic capture is unaffected and continues independently.

---

## Permissions

Two TCC permissions required:

- **Screen Recording** - for SCStream system audio capture. No entitlement, runtime-only. Check via `CGPreflightScreenCaptureAccess()`. Subject to monthly re-authorization on macOS 15+.
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

**Tradeoff accepted:** ~30 lines of AVAudioPCMBuffer-to-CMSampleBuffer conversion boilerplate. Timestamps use `AVAudioTime.hostTime` (`mach_absolute_time`, wall clock) converted via `CMClockMakeHostTimeFromSystemUnits` - same clock domain as SCStream's PTS, enabling direct multi-track alignment.

### D2: Remove post-recording audio mixing

**Decision:** Keep multi-track M4A as final output. No mixing step. Typically 3 tracks (display-wide + per-app + mic). Falls to 2 tracks when per-app is unavailable (multiple simultaneous callers, or unresolvable bundle ID).

**Previous implementation:** AVMutableComposition + AVAssetExportSession mixed dual-track to single-track after recording stopped.

**Why removed:** Four failure points at save time (load asset, create composition, run export session, atomic file replace). Blocks the save path. All modern players and transcription tools handle multi-track M4A. If single-track is ever needed, it should happen on export/share, not on save.

### D3: Polling-only call detection (remove CoreAudio listeners)

**Decision:** Detect calls by polling every 3 seconds. No CoreAudio property listeners.

**Previous implementation:** Event-driven CoreAudio listeners (process list + per-process IsRunningInput) with 3-second polling fallback.

**Why polling-only:** The polling fallback existed because listeners don't fire reliably for all audio pipelines - we already didn't trust them. Listeners added ~140 lines of code (N per-process listeners, Unmanaged pointer management, deinit cleanup, nonisolated(unsafe) state) for at best a few seconds of faster detection. For calls lasting minutes to hours, 0-3 second detection delay is imperceptible.

### D4: Input AND output check for call detection

**Decision:** A call is detected when a process has both `IsRunningInput` (mic active) AND `IsRunningOutput` (audio playing), excluding our own PID and ScreenCaptureKit helpers.

**Previous implementation:** Input-only check, which triggered on dictation, Siri, voice memos, voice search.

**Why both:** Input+output together identifies processes that are both capturing mic and playing audio - the defining characteristic of a call. Filters out most false positives without maintaining a hardcoded list of known call apps.

### D5: Dual-SCStream capture (display-wide + per-app)

**Decision:** Run two SCStream instances simultaneously. Display-wide captures all system audio (critical path, always runs). Per-app captures only the calling app's audio (best-effort, when single caller detected). Both write to the same AVAssetWriter as separate tracks.

**Previous implementation:** Single SCStream with per-app filter, falling back to display-wide when conditions were uncertain.

**Why dual:** Single per-app capture failed silently for Chrome/WebRTC (silence bug - Chrome's WebRTC audio bypasses CoreAudio per-process output). Display-wide guarantees completeness. Per-app provides a cleaner reference for AEC post-processing (just call audio, no notifications/music). Running both means nothing changes mid-recording - track layout is fixed at writer setup.

**Track layout (fixed at writer setup):**
- Track 0: display-wide audio (always, 2ch stereo)
- Track 1: per-app audio (when `bundleID != nil`, 2ch stereo)
- Track N (last): mic audio (when mic enabled, 1ch mono)

If per-app stream fails to start, Track 1 exists but is empty - file format stays consistent.

**Helper bundle ID resolution:** CoreAudio reports Chrome/Electron helper processes (e.g., `com.google.Chrome.helper.renderer`) as the audio client, not the main app. The `.helper` suffix is stripped to resolve to the parent app's bundle ID for SCContentFilter lookup.

**Per-app stream failure handling:** Log and continue. Set `appStreamFailed = true`. Do NOT call `onFailure` (non-critical). Display-wide has the audio regardless.

**Tradeoff accepted:** Per-app track may be empty (WebRTC apps) or contain only partial audio. Display-wide is the reliability backstop.

### D6: System notification for permission re-authorization

**Decision:** When Screen Recording permission is revoked (macOS 15+ monthly re-auth), send a system notification in addition to the menu bar indicator.

**Why:** During a call, the user is focused on the call app and may not notice the menu bar state change. System notifications appear in Notification Center regardless of focus. The notification informs the user that mic is still recording and guides them to re-authorize.

### D7: No Voice Processing (VPIO incompatible with SCStream)

**Decision:** Do not enable `setVoiceProcessingEnabled(true)` on AVAudioEngine's inputNode. Accept mic-side echo in dual-track recordings.

**The problem:** Without AEC, the mic track picks up the remote person's voice through speakers. Playing both tracks simultaneously produces audible echo/doubling. The track selector (Both/System/Mic) lets users isolate tracks during playback.

**Why VPIO was rejected:** Tested and confirmed that VPIO's aggregate device silences SCStream's system audio capture. VPIO hooks into the system audio output path to get its AEC reference signal, which interferes with SCStream's display-wide capture. The alona project independently confirmed: "When capturing system audio, voice processing causes audio quality issues." This is a fundamental incompatibility - VPIO and SCStream system audio cannot coexist.

**Alternatives considered:**
- **SCStream `.microphone`** (macOS 15+): Avoids VPIO conflict but delivers raw mic audio (no AEC). Loses automatic device following (the main reason we use AVAudioEngine - see D1).
- **Post-processing DSP**: No reliable open-source macOS implementation for echo cancellation.
- **CoreAudio Process Taps for system audio**: Different capture mechanism that might not conflict with VPIO, but major architectural change with uncertain benefit.

**Tradeoff accepted:** Mic track contains echo of remote audio. Mitigated by track selector in playback UI and TranscriptionService mixing tracks before upload to Soniox.

### D8: Silence gap filling for multi-track timeline integrity

**Decision:** Each capture pipeline tracks `nextExpectedTime` (PTS + duration of last written buffer). When an incoming buffer's PTS exceeds the expected time, write zero-filled silence buffers to fill the gap before writing the real buffer. Gap filling is best-effort - if it fails, the real buffer is still written. Never risk the recording for sync accuracy.

**The problem:** AVAssetWriter does not preserve PTS gaps. When a buffer arrives at t=12.5s after the last buffer ended at t=10.0s, the writer concatenates them back-to-back, making the track 2.5s shorter. Over a multi-hour recording with device switches, one track can become seconds shorter than the others, causing growing desync between tracks. Confirmed by Apple behavior, third-party production apps (RecordKit/Nonstrict), and empirical testing with a 2-hour recording where 4 mic device switches caused 8.64s of collapsed gaps.

**Why this affects Blackbox specifically:** Three independent capture pipelines (display-wide SCStream, per-app SCStream, AVAudioEngine mic) can each independently experience gaps. Mic device switches (Bluetooth connect/disconnect, Krisp activation) cause AVAudioEngine tap teardown/reinstall. SCStream can restart on permission revocation. Any gap in any track makes that track shorter, desynchronizing all tracks in the final M4A.

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

**Scope:** All three pipelines (display-wide, per-app, mic). While mic device switches are the most common source of gaps, SCStream restarts and permission revocations can gap any pipeline.
