# Blackbox Audio Architecture Specification

This document is the authoritative reference for Blackbox's audio capture architecture. All implementation decisions must align with this specification. When in doubt, reliability wins over features.

## Table of Contents

- [Design Principles](#design-principles)
- [System Overview](#system-overview)
- [Call Detection](#call-detection)
- [Audio Capture](#audio-capture)
- [File Writing](#file-writing)
- [Error Handling & Recovery](#error-handling--recovery)
- [Permissions](#permissions)
- [App Lifecycle](#app-lifecycle)
- [Decision Log](#decision-log)

---

## Design Principles

1. **Reliability over features.** A recording that silently fails is worse than a missing feature. Every architectural choice prioritizes "does the file get written correctly?"
2. **Independent failure domains.** System audio and mic capture are decoupled pipelines. Either can fail without taking down the other.
3. **Minimal moving parts.** Prefer polling over event-driven listeners. Prefer no post-processing over post-processing. Fewer code paths means fewer bugs.
4. **Let the OS do the work.** Use AVAudioEngine's automatic device following instead of manual CoreAudio listeners. Use Apple's voice processing instead of custom noise cancellation. Don't reimplement what the platform provides.

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
│  │  capturesAudio = true  │       │  inputNode.installTap()     │  │
│  │  captureMicrophone     │       │  voiceProcessingEnabled     │  │
│  │    = false             │       │                              │  │
│  │                        │       │  Follows system default      │  │
│  │  Display-wide filter   │       │  device automatically        │  │
│  │  excludesSelf = true   │       │                              │  │
│  │  No app exclusion list │       │  Restarts on configChange    │  │
│  │                        │       │  notification (sub-second)   │  │
│  │  width=2, height=2     │       │                              │  │
│  │  (audio-only)          │       │                              │  │
│  └───────────┬────────────┘       └──────────────┬───────────────┘  │
│              │                                   │                  │
│         CMSampleBuffer                    AVAudioPCMBuffer         │
│         (native)                                 │                  │
│              │                          ┌────────┴────────┐         │
│              │                          │    Convert to   │         │
│              │                          │  CMSampleBuffer │         │
│              │                          └────────┬────────┘         │
│              │                                   │                  │
└──────────────┼───────────────────────────────────┼──────────────────┘
               │                                   │
               ▼                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        WRITING                                      │
│                                                                     │
│  ┌──────────────────────┐       ┌──────────────────────┐            │
│  │  AVAssetWriterInput  │       │  AVAssetWriterInput  │            │
│  │  Track 1: system     │       │  Track 2: mic        │            │
│  └──────────┬───────────┘       └──────────┬───────────┘            │
│             │                              │                        │
│             └──────────┬───────────────────┘                        │
│                        ▼                                            │
│             ┌─────────────────────┐                                 │
│             │    AVAssetWriter    │                                  │
│             │    .m4a / AAC      │                                  │
│             │    48kHz stereo    │                                  │
│             │    128kbps         │                                  │
│             │                    │                                  │
│             │    movieFragment   │                                  │
│             │    Interval = 10s  │                                  │
│             │    (crash safety)  │                                  │
│             └──────────┬─────────┘                                  │
│                        │                                            │
└────────────────────────┼────────────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────┐
              │    audio.m4a     │
              │                  │
              │  Track 1: system │
              │  Track 2: mic    │
              │                  │
              │  Dual-track,     │
              │  no mixing       │
              └──────────────────┘
```

---

## Call Detection

### Approach: Polling-Only Per-Process Audio State

Every 3 seconds, scan the CoreAudio process list and check which processes have active audio I/O.

```
Every 3 seconds:
  allAudioProcessObjects()                    // kAudioHardwarePropertyProcessObjectList
    → for each process:
        isRunningInput?                       // kAudioProcessPropertyIsRunningInput
        isRunningOutput?                      // kAudioProcessPropertyIsRunningOutput
        pid != myPID?                         // filter self
        bundleID not screencapturekit/replayd? // filter SCK helpers
    → processes with BOTH input AND output = active calls
```

### Why Polling, Not Listeners

Previous implementation used CoreAudio property listeners (event-driven) with a polling fallback. The listeners required:

- 1 process list listener + N per-process input listeners
- `Unmanaged.passUnretained` pointer management for C callbacks
- Listener add/remove bookkeeping as processes come and go
- `nonisolated(unsafe)` state for deinit cleanup
- ~140 lines of listener management code

The polling fallback existed because **listeners don't fire reliably for all audio pipelines**. Since we polled every 3 seconds anyway, the listeners added complexity for at best a few seconds of faster detection - irrelevant for calls that last minutes to hours.

Polling-only eliminates all listener code, pointer management, and deinit cleanup. Detection delay of 0-3 seconds is imperceptible for the use case.

### Why Input AND Output Check

Checking only for mic input (IsRunningInput) triggers on any app that opens the mic: dictation, Siri, voice memos, voice search. Adding the output check (IsRunningOutput) filters these out - a call has both mic input (user speaking) and speaker output (remote party audio). This eliminates most false positives without maintaining a list of known call apps.

### Grace Period

When all external mic+output processes disappear, a configurable grace period (default 5 seconds) runs before stopping the recording. This handles brief connection drops, hold/unhold, and the moment between a participant leaving and the call truly ending.

### References

- `kAudioHardwarePropertyProcessObjectList` - enumerate audio processes (macOS 14.2+)
- `kAudioProcessPropertyIsRunningInput` - per-process mic activity
- `kAudioProcessPropertyIsRunningOutput` - per-process audio output activity
- `kAudioProcessPropertyPID` - get PID for filtering
- `kAudioProcessPropertyBundleID` - get bundle ID for app name resolution

---

## Audio Capture

### System Audio: ScreenCaptureKit SCStream

ScreenCaptureKit is the only supported, documented way to capture system audio on macOS. There are no viable alternatives for shipping software.

**Configuration:**

```swift
let config = SCStreamConfiguration()
config.capturesAudio = true
config.sampleRate = 48000
config.channelCount = 2
config.excludesCurrentProcessAudio = true
config.captureMicrophone = false          // mic handled by AVAudioEngine

// Audio-only: minimize video overhead
// SCK requires a .screen output even for audio-only capture
config.width = 2
config.height = 2
config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
config.showsCursor = false
```

**Content filter:** Display-wide capture with no app exclusion list. Previous implementation excluded virtual audio processors (Krisp, SoundSource, Loopback) by hardcoded bundle ID prefix to prevent voice duplication. This was fragile (missed unknown apps) and potentially wrong (excluded apps whose audio the user may want captured). With `captureMicrophone = false`, SCStream no longer opens the mic, so the duplication concern from virtual audio processors does not apply to the system audio path.

**Why not SCRecordingOutput:** SCRecordingOutput (macOS 15+) is Apple's high-level recording API that handles AVAssetWriter internally and automatically mixes mic + system audio. However, it has a documented limitation: updating SCStreamConfiguration on a running stream stops the recording. This is confirmed in the `SCStream.h` header: "In case client update the stream configuration during recording, recording will be stopped as well." Since SCRecordingOutput also lacks crash safety (no movieFragmentInterval equivalent), and would require a post-processing step to strip the video track, it offers no advantage over manual AVAssetWriter for our audio-only use case.

> Source: `SCStream.h` header, macOS 15.0 SDK (Xcode 16.0). Limitation unchanged through macOS 15.4 and macOS 26 Tahoe beta 2.

### Microphone Audio: AVAudioEngine

AVAudioEngine captures mic audio independently from SCStream. This is the core architectural decision - two independent capture pipelines with no shared state.

**Why AVAudioEngine over SCStream `.microphone`:**

| Concern | SCStream .microphone | AVAudioEngine |
|---|---|---|
| Device following | Manual: CoreAudio listener + `updateConfiguration()` which can fail, splitting the recording into separate files | Automatic: inputNode follows system default device. On hardware change, observe `AVAudioEngineConfigurationChange`, reinstall tap, restart. Sub-second gap, same file. |
| Independence | Tied to SCStream lifecycle. If stream dies, mic dies. | Fully independent. If SCStream dies (permission revoked), mic keeps recording. |
| Virtual audio compatibility | With `captureMicrophone = true`, Krisp/SoundSource exclusion list needed to prevent voice duplication | No interaction with SCStream's audio path. No exclusion list needed. |
| Voice processing | Not available | `setVoiceProcessingEnabled(true)` on inputNode. Apple's built-in noise reduction, echo cancellation, AGC - for free. |
| Output format | CMSampleBuffer (native) | AVAudioPCMBuffer (requires ~30 lines conversion) |

**Device change handling:**

```
Physical device change (e.g., switch to AirPods)
    │
    ▼
AVAudioEngineConfigurationChange notification
    │
    ▼
Engine has stopped internally
inputNode now points to new default device
    │
    ▼
Reinstall tap on inputNode + engine.start()
    │
    ▼
Recording resumes from new device (sub-second gap, same file)
```

When the system default input is a virtual device (e.g., "Krisp Microphone"), device switching inside the virtual audio app (e.g., switching physical mics in Krisp's UI) is invisible to AVAudioEngine - the system default doesn't change, so no restart is needed. This is the most common scenario for users with virtual audio processors.

**Voice processing:** `setVoiceProcessingEnabled(true)` on AVAudioEngine's inputNode activates Apple's voice processing pipeline (same technology as FaceTime). This includes noise suppression, acoustic echo cancellation, and automatic gain control. It processes only our copy of the audio stream - the call app's audio pipeline is completely unaffected. Enabled by default, togglable in settings.

**PCM-to-CMSampleBuffer conversion:** AVAudioEngine delivers `AVAudioPCMBuffer`. AVAssetWriterInput requires `CMSampleBuffer`. The conversion is ~30 lines of fixed boilerplate code that creates timing info from the host clock and copies PCM data into a CMSampleBuffer.

> Reference sources:
> - [Apple ScreenCaptureKit documentation](https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos)
> - [Apple Developer Forums thread 727709](https://developer.apple.com/forums/thread/727709)
> - [aibo-cora/CMSampleBuffer gist](https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c)
> - [Azayaka](https://github.com/Mnpn/Azayaka) by Martin Persson (architectural reference for ScreenCaptureKit audio patterns)

### Why Two Independent Pipelines

The decoupled architecture means:

- **SCStream dies** (permission revoked, system error) → mic keeps recording via AVAudioEngine. User's side of the conversation is preserved.
- **AVAudioEngine dies** (device disappears, engine error) → system audio keeps recording via SCStream. Remote side of the conversation is preserved.
- **Device switch** → only AVAudioEngine restarts. SCStream is unaffected. No interruption to system audio capture.
- **No shared state** between the two pipelines. No coordination needed. No cascading failures.

---

## File Writing

### AVAssetWriter with Dual-Track M4A

Both capture pipelines write to a single AVAssetWriter as separate tracks:

- **Track 1:** System audio (from SCStream `.audio` callback) - CMSampleBuffer appended directly
- **Track 2:** Mic audio (from AVAudioEngine tap) - AVAudioPCMBuffer converted to CMSampleBuffer, then appended

**Session start:** The writer session starts on the first system audio sample's presentation timestamp. Mic samples arriving before the session starts are dropped (guard on `sessionStarted` flag). This matches the pattern used by Azayaka's AVAudioEngine integration.

**Settings:**

```swift
AVAssetWriter(url: audioURL, fileType: .m4a)
writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

// Both tracks use identical settings
let audioSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: 48000.0,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitRateKey: 128_000,
]
```

### No Post-Processing

The dual-track M4A is the final output. No mixing, no track stripping, no post-processing of any kind.

**Why no mixing:** Previous implementation mixed dual-track to single-track via AVMutableComposition + AVAssetExportSession after recording stopped. This added four failure points at save time (load asset, create composition, run export session, atomic file replace) and blocked the save path. Modern players (QuickTime, VLC), transcription tools (Whisper), and audio editors all handle multi-track M4A correctly. The mixing step added fragility for no practical benefit.

If single-track output is ever needed for a specific downstream tool, it should be done lazily on export/share, not in the recording path.

### Crash Safety

`movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)` writes fragment headers every 10 seconds. If the app crashes, the Mac loses power, or the process is force-killed, the file is recoverable up to the last fragment boundary. Worst case: 10 seconds of audio lost. This is critical for a call recorder that may run unattended for hours.

### Threading Model

AVAssetWriter state (`writer`, `audioInput`, `micInput`, `sessionStarted`, `stopped`) is accessed exclusively from a serial dispatch queue (`audioQueue`). SCStreamOutput callbacks run on this queue. The `stop()` method dispatches `markAsFinished()` onto `audioQueue.sync` to serialize with callbacks.

This requires `nonisolated(unsafe)` annotations in Swift 6 strict concurrency mode because the compiler cannot verify the serial queue discipline. The safety guarantee is structural, not compiler-enforced.

---

## Error Handling & Recovery

### SCStream Errors

`SCStreamDelegate.stream(_:didStopWithError:)` fires when the stream dies unexpectedly. Error codes are mapped to `RecorderFailure` cases:

| Code | Failure | Recovery |
|---|---|---|
| -3801 | `.permissionDenied` | Set `permissionNeeded = true`, send system notification, stop recording. Mic track (AVAudioEngine) continues independently. |
| -3802 | `.systemStopped` | Auto-restart with rate limiting (max 3 restarts in 30 seconds). |
| -3820 | `.micFailed` | N/A - mic is no longer captured via SCStream. |
| -3821 | `.systemStopped` | Same as -3802. |
| Other | `.other(description)` | Log, notify user, stop recording. |

### AVAudioEngine Errors

On `AVAudioEngineConfigurationChange` notification: reinstall tap on `inputNode`, call `engine.start()`. This handles all device changes (plugging/unplugging headphones, Bluetooth connects/disconnects, switching default device in System Settings, virtual audio app changes).

If `engine.start()` throws: log the error, continue recording system audio only. Mic track is lost but system audio track is preserved.

### Auto-Restart Rate Limiting

Maximum 3 restarts within a 30-second window. If exceeded, recording stops and the user is notified. This prevents infinite restart loops from persistent errors (e.g., hardware failure, driver crash).

### Disk Space Monitoring

Checked every 30 seconds on the `audioQueue`:
- Below 500 MB: warning notification to user
- Below 100 MB: recording stopped to prevent system instability

Pre-recording check: if less than 50 MB free, recording refuses to start.

---

## Permissions

### Screen Recording (TCC)

Required for SCStream system audio capture. No entitlement - governed entirely by macOS TCC runtime permission.

```swift
// Check without prompting
CGPreflightScreenCaptureAccess()

// Trigger system prompt
CGRequestScreenCaptureAccess()
```

**macOS 15+ monthly re-authorization:** Apple shows periodic re-authorization prompts. If the user doesn't re-authorize, SCStream dies with error code -3801. The app should:

1. Detect permission denial via SCStreamDelegate error callback
2. Send a UNUserNotificationCenter system notification: "System audio lost - your mic is still recording. Re-authorize Screen Recording to capture both sides."
3. Set `permissionNeeded = true` to show the menu bar warning state
4. AVAudioEngine mic capture continues independently - user's side of the conversation is preserved

System notifications are used (not just the menu bar indicator) because the user may be focused on their call app and not see the menu bar state change. System notifications appear in Notification Center and are visible regardless of focus.

### Microphone (TCC)

Required for AVAudioEngine mic capture. Requires `NSMicrophoneUsageDescription` in Info.plist and `com.apple.security.device.audio-input` entitlement.

```swift
AVCaptureDevice.authorizationStatus(for: .audio)
await AVCaptureDevice.requestAccess(for: .audio)
```

Checked at app launch. If not granted, mic capture is skipped but system audio recording still works.

---

## App Lifecycle

### Startup

1. `applicationDidFinishLaunching`: check onboarding state
2. `startMonitoring()`: load settings, begin 3-second polling loop
3. If first launch: show onboarding window for permissions walkthrough
4. If permissions already granted: detection begins immediately

### During Recording

Two independent pipelines run concurrently:
- SCStream delivers system audio on `audioQueue`
- AVAudioEngine delivers mic audio on its internal thread
- Both write to the same AVAssetWriter (serialized on `audioQueue`)
- Polling continues to detect call end

### Graceful Shutdown

`applicationShouldTerminate` returns `.terminateLater` to allow async cleanup:

1. Cancel polling task
2. Stop AVAudioEngine (instant)
3. Stop SCStream (`stopCapture()`)
4. Finalize AVAssetWriter (`markAsFinished()` on `audioQueue.sync`, then `finishWriting()`)
5. Reply to terminate

8-second timeout: if cleanup doesn't complete, the app terminates anyway. `movieFragmentInterval` ensures the file is recoverable up to the last 10-second boundary.

### Force Quit / Crash

`movieFragmentInterval` writes fragment headers every 10 seconds. The M4A file is valid and playable up to the last fragment, losing at most 10 seconds of audio. No special recovery code needed - the file just works when opened.

---

## Decision Log

Architectural decisions made during the design review, with reasoning and alternatives considered.

### D1: AVAudioEngine for mic instead of SCStream .microphone

**Decision:** Use AVAudioEngine tap on inputNode for mic capture. Set `captureMicrophone = false` on SCStream.

**Alternatives considered:**
- **SCStream `.microphone`** (previous implementation): requires manual device following via CoreAudio listener + `updateConfiguration()`. On failure, recording splits into separate files. Tied to SCStream lifecycle.
- **AVCaptureSession + AVCaptureAudioDataOutput**: gives CMSampleBuffer natively (no conversion), structured interruption notifications. But requires manual device switching similar to the SCStream approach - doesn't solve the core problem.

**Why AVAudioEngine wins:** Automatic device following via inputNode. One `AVAudioEngineConfigurationChange` notification handler replaces ~140 lines of CoreAudio listener management. Device switches cause a sub-second gap in the same file instead of a recording split. Independent from SCStream - mic survives SCStream death.

**Tradeoff accepted:** ~30 lines of AVAudioPCMBuffer-to-CMSampleBuffer conversion boilerplate.

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

### D5: Remove virtual audio processor exclusion list

**Decision:** No hardcoded bundle ID prefix list for filtering apps from display-wide capture.

**Previous implementation:** Excluded `ai.krisp`, `com.rogueamoeba.SoundSource`, `com.rogueamoeba.loopback` from SCContentFilter.

**Why removed:** With `captureMicrophone = false` on SCStream, the voice duplication scenario (virtual audio processor's processed mic output captured as system audio + raw mic captured separately) does not apply. The exclusion list was also fragile (missed unknown apps, could exclude audio the user wants captured) and based on a potentially incorrect assumption about how virtual audio processors route audio.

### D6: Apple Voice Processing on AVAudioEngine

**Decision:** Enable `setVoiceProcessingEnabled(true)` on AVAudioEngine's inputNode by default. Togglable in settings.

**Why:** Built-in noise suppression, echo cancellation, and automatic gain control for free. One line of code. Processes only our copy of the audio - does not affect the call app's audio pipeline. Same technology as FaceTime.

### D7: System notification for permission re-authorization

**Decision:** When Screen Recording permission is revoked (macOS 15+ monthly re-auth), send a `UNUserNotificationCenter` system notification in addition to the menu bar indicator.

**Why:** During a call, the user is focused on the call app and may not notice the menu bar state change. System notifications appear in Notification Center and are visible regardless of focus. The notification informs the user that mic is still recording (AVAudioEngine is independent) and guides them to re-authorize.

---

## File Format Reference

### Recording Directory Structure

```
~/Library/Application Support/Blackbox/Recordings/
  └── 2026-03-10-143022-A1B2/
        ├── audio.m4a          # dual-track: system (track 1) + mic (track 2)
        └── metadata.json      # title, timestamp, app name, speakers
```

### Audio Settings

| Property | Value |
|---|---|
| Container | M4A |
| Codec | AAC (kAudioFormatMPEG4AAC) |
| Sample rate | 48,000 Hz |
| Channels | 2 (stereo) |
| Bit rate | 128 kbps per track |
| Fragment interval | 10 seconds (crash safety) |
| Tracks | Track 1: system audio, Track 2: mic audio |

### Approximate File Sizes

| Duration | Size (both tracks) |
|---|---|
| 1 minute | ~2 MB |
| 30 minutes | ~60 MB |
| 1 hour | ~120 MB |
| 3 hours | ~360 MB |
