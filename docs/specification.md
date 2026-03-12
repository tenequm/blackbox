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
│  ┌────────────────────────┐       ┌──────────────────────────────┐  │
│  │      SCStream          │       │      AVAudioEngine           │  │
│  │                        │       │                              │  │
│  │  System audio only     │       │  Mic via inputNode tap       │  │
│  │  captureMicrophone     │       │                              │  │
│  │    = false             │       │  Follows system default      │  │
│  │  Per-app filter         │       │                              │  │
│  │  Display-wide fallback  │       │                              │  │
│  └───────────┬────────────┘       └──────────────┬───────────────┘  │
│              │                                   │                  │
│              ▼                                   ▼                  │
│         CMSampleBuffer                    CMSampleBuffer            │
│         (native)                          (converted from PCM)      │
│              │                                   │                  │
└──────────────┼───────────────────────────────────┼──────────────────┘
               │                                   │
               ▼                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        WRITING                                      │
│                                                                     │
│         AVAssetWriter → dual-track M4A (AAC, 48kHz, 128kbps)       │
│         Track 1: system audio    Track 2: mic audio                 │
│         movieFragmentInterval = 10s (crash safety)                  │
│         No post-processing, no mixing                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Key Architectural Constraints

These are non-obvious constraints discovered during implementation that future changes must respect.

- **AVAssetWriterInput format is immutable.** The internal encoder configures from the first appended buffer's format description. Mid-stream format changes cause `append()` to fail and the writer to enter `.failed` state, losing both tracks. This is why the mic tap must reinstall with the original format on device change.

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

**Decision:** Keep dual-track M4A as final output. No mixing step.

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

### D5: Per-app audio capture with display-wide fallback

**Decision:** When a single calling app is detected, capture only that app's audio via `SCContentFilter(display:including:[app])`. Fall back to display-wide capture when conditions are uncertain.

**Previous implementation:** Display-wide capture with no app exclusion list. Before that, a hardcoded exclusion list for Krisp, SoundSource, Loopback.

**Why per-app:** Display-wide capture picks up audio from virtual audio processors (Krisp, Loopback, etc.) that create delayed copies of the call audio in their output path. This causes audible echo/duplication in recordings - confirmed via autocorrelation analysis showing ~53ms signal duplication from Krisp's speaker processing. Per-app capture inherently excludes these processors since they are separate processes.

**Why not an exclusion list:** The previous exclusion list approach was fragile (missed unknown apps, could exclude audio the user wants). Per-app capture solves the problem generically without maintaining a list.

**Helper bundle ID resolution:** CoreAudio reports Chrome/Electron helper processes (e.g., `com.google.Chrome.helper.renderer`) as the audio client, not the main app. The `.helper` suffix is stripped to resolve to the parent app's bundle ID for SCContentFilter lookup.

**Fallback to display-wide when:**
- Bundle ID is nil (process has no bundle identifier)
- Multiple calling apps detected simultaneously (can't pick one)
- Target app not found in SCShareableContent (crash recovery, race condition)

**Tradeoff accepted:** Per-app capture excludes notification sounds and other apps' audio during calls. This is desirable for call recording - cleaner output with only call audio.

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
