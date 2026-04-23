# Audio Capture Research

Research on system audio + mic capture synchronization on macOS, conducted April 2026.

> **Status note (v0.8.0):** This document captures the research that motivated the v0.7.0 CATap migration. The CATap migration was reverted in v0.8.0 because CATap's clock source (aggregate-device hardware output clock) produced silent-recording failures whenever that clock was idle/pinned/stalled. Display-wide SCStream - same pipeline described under "Current Architecture (v0.6.0)" minus the per-app best-effort stream - is the shipping capture backend again. The CATap evaluation below is kept as historical context, not as a recommendation. See `specification.md` D10 for the revert rationale. v0.8.0 also documents a known `AVAudioEngineConfigurationChange` gap (missed same-format default-input switches) and adds a CoreAudio default-input listener plus a buffer-arrival watchdog to close it - see `specification.md` D12.

## Current Architecture (v0.6.0)

- **System audio**: Dual SCStream (display-wide + per-app) via ScreenCaptureKit
- **Mic**: AVAudioEngine `inputNode.installTap()`
- **Output**: 2-3 track M4A via AVAssetWriter
- **AEC**: Post-recording DTLN-aec CoreML
- **Gap handling**: Silence insertion on PTS discontinuity (D8)

## Why SCStream Was Chosen (March 2026)

Decision made after evaluating all system audio capture options:

1. **SCStream (chosen)**: `capturesAudio = true`, delivers CMSampleBuffer via SCStreamOutput delegate, supports display-wide or per-app filtering, requires Screen Recording TCC permission
2. **CATap (`AudioHardwareCreateProcessTap`, macOS 14.2+)**: Dismissed as "low-level C API, essentially undocumented beyond header comments, no Apple sample code, no WWDC coverage"
3. **Virtual Audio Device (BlackHole, Soundflower)**: Not viable - can't ship a kernel-adjacent driver as part of a menu bar app
4. **Aggregate Device Trick**: Unreliable, can interfere with user's audio routing
5. **AVCaptureScreenInput**: Deprecated in macOS 15
6. **CGDisplayStream**: Limited audio support, dead end

Positive case for SCStream:
- Display-wide capture (all apps) with no per-process targeting needed
- CMSampleBuffer output ready for AVAssetWriter (no conversion)
- Device change transparent (system audio continues when output device changes)
- Mature, well-documented API with WWDC sessions

## Why AVAudioEngine Was Chosen for Mic (March 2026)

Five approaches evaluated:

| Approach | Verdict | Key Factor |
|----------|---------|------------|
| SCStream `.microphone` (macOS 15+) | Rejected | Documented bugs (corrupted files), XPC PID uncertainty, couples recording+detection |
| **AVAudioEngine tap** | **Chosen** | Automatic device following, mature API (10+ years), mic opens under app's PID |
| AVCaptureSession | Rejected | Manual device switching required, more setup code |
| CoreAudio AudioUnit (HAL Input) | Rejected | Low-level, no clear benefit over AVAudioEngine |
| Don't capture mic | Rejected | Mic needed for call recording |

AVAudioEngine's killer feature: **automatic device following**. On hardware change, `AVAudioEngineConfigurationChange` notification fires, tap is reinstalled, sub-second gap, same file. With Krisp as system default, most device switching happens inside Krisp and is invisible to AVAudioEngine.

> **Caveat (discovered April 2026):** AVAudioEngine's automatic device following is reliable for format-changing switches, but it silently misses same-format default-input swaps. See "AVAudioEngine Device-Follow Gaps" below and `specification.md` D12.

## Why Dual SCStream (v0.6.0)

Eliminates mid-recording decisions:
- Display-wide always runs (safety net, guaranteed completeness)
- Per-app is best-effort bonus (cleaner AEC reference when available)
- Nothing changes mid-recording - pipeline is stateless after start

## The Sync Problem

Both pipelines use `mach_absolute_time` (host time clock), but:

1. **Constant latency offset**: SCStream has ~20-50ms internal buffering delay; AVAudioEngine delivers with ~50-70ms hardware latency from a different pipeline point
2. **Gap-induced desync**: Device switches cause PTS gaps that AVAssetWriter collapses, making mic track progressively shorter (8.64s over 2 hours in production)
3. **Clock drift**: Potentially ~50 PPM between device clocks (~180ms/hour worst case), but empirical evidence shows the drift is from lost samples during device switches, not actual clock rate differences

Gap-induced desync was fixed in v0.6.1 with silence gap filling (D8). The constant latency offset remains.

## CATap (Core Audio Process Tap) - Re-evaluation April 2026

Original assessment (March 2026) dismissed CATap as undocumented with unclear permissions. Re-evaluation found:

### Advantages Over SCStream

- **Better permission model**: `NSAudioCaptureUsageDescription` (audio-only, one-click grant) vs Screen Recording (broad, app restart required)
- **No Chrome/WebRTC silence bug**: CATap captures at HAL level, below any private audio paths
- **Lower latency**: IO proc callback vs SCStream's higher-level buffering
- **Built-in drift compensation**: `kAudioSubTapDriftCompensationKey: true` on aggregate device

### Disadvantages vs SCStream

- **Low-level C/ObjC API**: Poorly documented, requires careful lifecycle management
- **Device change handling**: Must tear down entire aggregate device and rebuild on output device change (0.5-1.5s gap)
- **Per-process targeting only**: `CATapDescription` targets specific PIDs. For "all system audio", need `stereoGlobalTapButExcludeProcesses` (exclude own PID)
- **Raw audio output**: Delivers interleaved Float32, needs manual conversion to CMSampleBuffer
- **AudioDeviceStart hang**: Starting a physical mic input while aggregate device is running blocks forever. Must stop aggregate, start mic, restart aggregate.

### Production Usage

- **RecordKit (Nonstrict)**: Made CATap default backend in v0.82.0, moving away from SCStream for audio. Fixed "audio drift caused by clock domain mismatch" in v0.78.0.
- **Chromium**: Added `CatapAudioInputStream` in 2025 behind feature flag
- **Muesli**: Uses CATap + real-time WebRTC AEC3 pipeline

### Critical Finding: CATap Does NOT Solve Mic-System Sync

**No one puts mic in the CATap aggregate device.** Every implementation (AudioCap, audiotap, AudioCaptureKit, Muesli, RecordKit, Chromium) captures system audio via CATap and mic separately. The drift compensation key only handles system-audio-internal drift, not mic-vs-system drift.

RecordKit still needed:
- `audioDelay` constant offset compensation (v0.51.0)
- Post-recording audio stretching for drift (frame duplication)
- WebRTC AEC3 for echo cancellation (v0.77.0)

## Reference Implementations

### insidegui/AudioCap (490 stars, BSD-2)
- Cleanest CATap reference (~180 lines)
- System audio only, no mic
- Uses `kAudioSubTapDriftCompensationKey: true`
- By Guilherme Rambo (well-known macOS developer)

### graphaelli/audiotap (Apache-2.0)
- C library, system audio + mic
- Documents AudioDeviceStart hang bug and workaround
- Mic device following via `kAudioHardwarePropertyDefaultInputDevice` listener
- No sync between streams (provides host_time for caller to align)
- 87 tests with 100% coverage

### dburkhardt/muesli (macOS meeting recorder)
- Most sophisticated sync pipeline (AudioSynchronizer + DriftTracker + CoarseDelayController)
- ~3000 lines of sync code for real-time AEC - overkill without real-time AEC
- CATap for system, separate IO proc for mic (NOT in same aggregate)
- AEC non-convergence is biggest open issue (#41)
- Drift is measured but NOT corrected in audio path

### Nonstrict RecordKit (commercial SDK)
- Migrated SCStream -> CATap (v0.50.0 beta, v0.82.0 default)
- `audioDelay` offset compensation
- Post-recording audio stretching for drift
- WebRTC AEC3 (balanced and aggressive presets)
- Blog posts: gap handling, audio stretching techniques

### pablo-health/AudioCaptureKit (AGPL-3.0)
- Swift 6, CATap system + AVAudioEngine mic
- Ring buffer mixing (Left = mic + system L, Right = mic + system R)
- AGPL license blocks closed-source use

## Apple's Official CATap Sample Code
- Published for macOS 26.0+ (WWDC 2026)
- Covers: CATapDescription, aggregate device, tap setup
- Does NOT cover: mic capture, synchronization, drift correction, device changes

## Approaches to Fix Mic-System Alignment

### 1. Post-Recording Cross-Correlation (Quick Win)
- After recording, measure actual offset via cross-correlation
- Apply during AEC post-processing step (already have infrastructure)
- Works because mic picks up system audio bleed (speaker -> mic path)
- Robust to hardware variation, handles any offset automatically
- Limitation: only works when system audio bleeds into mic

### 2. Constant Offset Compensation (What RecordKit Does)
- Query CoreAudio device latencies (`kAudioDevicePropertyLatency`, `kAudioStreamPropertyLatency`, `kAudioDevicePropertySafetyOffset`)
- Apply as constant PTS shift to mic samples
- Apple engineers confirmed: "no way to get accurately timed information from input relative to output without manual calibration"
- Hardware-dependent, not perfect

### 3. CATap Migration + audioDelay (Medium-Term)
- Replace SCStream with CATap for system audio
- Keep AVAudioEngine for mic
- Add constant audioDelay compensation
- Benefits: better permissions, no Chrome silence bug, lower latency
- Does not automatically solve sync

### 4. Real-Time Sync Pipeline (Muesli Approach)
- Ring buffers + sample-index timeline + drift tracking + WebRTC AEC3
- ~3000 lines of complex, RT-safe synchronization code
- Only justified if doing real-time AEC during recording
- Overkill for post-recording AEC approach

## Key Insight

The sync problem has two independent components:
1. **PTS gap collapse** (device switches) - SOLVED in v0.6.1 with silence gap filling
2. **Constant latency offset** (pipeline processing delays) - NOT yet solved

Component 2 is inherent to any dual-pipeline architecture. Even CATap doesn't solve it because mic is always a separate stream. The practical solutions are post-recording alignment or constant offset compensation.

## AVAudioEngine Device-Follow Gaps (April 2026)

Investigation triggered by a v0.8.0 smoke test failure: `recording survives default input device switch mid-capture` passed 2 of 4 runs on the same machine in the same 2-minute window. Root cause research uncovered a class of silent-failure cases AVAudioEngine's notification does not cover.

### Finding: Same-format default-input swaps do not post `AVAudioEngineConfigurationChange`

`AVAudioEngine.inputNode` binds to a hidden default-input aggregate device at tap-install time. macOS rebuilds that aggregate - and posts `AVAudioEngineConfigurationChange` - only when the new hardware forces a format change (sample rate, channel count, etc.). When the default input swaps between two devices of identical format (two 48 kHz mics, monitor auto-claiming default, same-format USB fallback), the aggregate silently re-points its HAL endpoint but the engine is never notified; the tap keeps pulling from the old endpoint, which is no longer producing samples. Mic stalls with no error.

### Empirical reproduction

In the v0.8.0 smoke suite, 2 of 4 consecutive `inputDeviceSwitchDuringRecording` runs stalled the mic PTS for ~4.9 s. Passing runs had alternates with different formats (AirPods HFP at 24 kHz); failing runs had alternates at 48 kHz. Failure correlates cleanly with format-match.

### External evidence

- **Apple Developer Forums thread 71008** - definitive community discussion of macOS aggregate-rebuild-on-format-change behavior; Apple engineer participation.
- **AudioKit issue #2130** - concrete non-firing cases with workaround using CoreAudio property listener.
- **Chromium `CatapAudioInputStream`** and several other shipping recorders register a `kAudioHardwarePropertyDefaultInputDevice` listener rather than relying on `AVAudioEngineConfigurationChange` alone.

### What neither `AVAudioEngineConfigurationChange` nor a default-input listener catches

- Virtual audio devices (BlackHole, Loopback, etc.) internally re-routing their upstream source without changing device ID or format.
- AirPods A2DP↔HFP transport flips that preserve device ID while stalling buffer delivery.
- `kAudioDevicePropertyDeviceIsAlive` going false on a still-default device (USB hub glitch, Continuity Mic locking, iPhone leaving Bluetooth range).
- Unknown unknowns that the OS never signals.

The only signal that is agnostic to what CoreAudio decides to tell us is **the absence of buffers themselves**. This motivates the watchdog leg of D12.

### Outcome → D12

Blackbox ships a three-layer mic-recovery design in v0.8.0:
1. `AVAudioEngineConfigurationChange` observer (existing, fast, covers format-changing switches reliably).
2. `kAudioHardwarePropertyDefaultInputDevice` listener (new, closes the same-format default-input hole proven by the smoke suite).
3. Buffer-arrival watchdog on `audioQueue` with 2 s trip threshold (new, universal safety net - catches virtual-driver crashes, in-place transport flips, device-death-without-default-change, and unknown-unknowns).

All three signals feed the same debounced teardown/reinstall path. See `specification.md` D12 for the full decision.
