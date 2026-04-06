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

- **AVAssetWriter collapses PTS gaps.** When audio buffers have a timestamp discontinuity (gap between last buffer's end and next buffer's start), the writer concatenates samples back-to-back, making the track shorter. Gaps must be filled with explicit zero-filled silence buffers to preserve timeline integrity. No AVAssetWriter setting changes this behavior.

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

**Tradeoff accepted:** ~30 lines of AVAudioPCMBuffer-to-CMSampleBuffer conversion boilerplate. Timestamps use `AVAudioTime` from tap callback converted via `CMClockMakeHostTimeFromSystemUnits` for accurate multi-track sync.

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

**Decision:** Each capture pipeline tracks `nextExpectedTime` (PTS + duration of last written buffer). When an incoming buffer's PTS exceeds the expected time, write zero-filled silence buffers to fill the gap before writing the real buffer.

**The problem:** AVAssetWriter does not preserve PTS gaps. When a buffer arrives at t=12.5s after the last buffer ended at t=10.0s, the writer concatenates them back-to-back, making the track 2.5s shorter. Over a multi-hour recording with device switches, one track can become seconds shorter than the others, causing growing desync between tracks. Confirmed by Apple behavior, third-party production apps (RecordKit/Nonstrict), and empirical testing with a 2-hour recording where 4 mic device switches caused 8.64s of collapsed gaps.

**Why this affects Blackbox specifically:** Three independent capture pipelines (display-wide SCStream, per-app SCStream, AVAudioEngine mic) can each independently experience gaps. Mic device switches (Bluetooth connect/disconnect, Krisp activation) cause AVAudioEngine tap teardown/reinstall. SCStream can restart on permission revocation. Any gap in any track makes that track shorter, desynchronizing all tracks in the final M4A.

**Why not just use correct timestamps:** The mic tap already uses `AVAudioTime.hostTime` (wall clock) for PTS, so timestamps correctly reflect the gap. But AVAssetWriter's AAC encoder ignores timestamp discontinuities and concatenates samples. There is no AVAssetWriter property or setting to change this behavior.

**Implementation constraints:**
- Silence buffers must match the normal buffer size (~1024 samples). One large silent buffer spanning the entire gap crashes the AAC encoder.
- The `CMFormatDescription` of silence buffers must match the real buffers from that pipeline.
- Gap detection threshold should account for normal timing jitter (a few ms). Only fill gaps above ~10ms.
- Gap filling runs on `audioQueue`, same as all other writer state mutations.

**Scope:** All three pipelines (display-wide, per-app, mic). While mic device switches are the most common source of gaps, SCStream restarts and permission revocations can gap any pipeline.
