# Mic reconfiguration must not run on the SCStream delivery queue

Plan for #31. Written 2026-09-09 against `main` at `2e4c2d4`; line numbers are
from that commit.

## What breaks

`AudioRecorder.swift:226` gives SCStream `audioQueue` as its
`sampleHandlerQueue`. `handleEngineConfigChange` (`AudioRecorder.swift:786`)
runs `ObjCGetInputNode`, `ObjCRemoveTap` and `inputFormat(forBus:)`
synchronously on that same queue. Any blocking HAL call there stops system
audio capture for its full duration, and ScreenCaptureKit **drops** buffers
when its handler queue is blocked rather than queueing them - so the audio is
gone at the framework boundary, with nothing to recover once the queue drains.

Reported: 683 s of block, ~687 s of system audio lost from a two-hour call, no
error surfaced, transcription of the truncated file succeeded.

Reproduced locally against the 0.9.4 bundle by switching the default input mid
recording:

| switch | block | system audio lost |
| --- | --- | --- |
| AirPods Pro -> built-in mic | 0.6 s | yes |
| built-in -> AirPods Pro (24 kHz HFP) | 0.5 s | yes |
| AirPods -> iPhone Continuity mic | 2.0 s | yes |

126.0 s of wall clock produced a 123.97 s system track and a 125.40 s mic
track, with `system stats: received=6196 appended=6196 notReady=0
appendFail=0`. The pipeline dropped nothing; those buffers were never
delivered to it. The stall length is device-specific, the loss is not.

## The design in five lines

1. A dedicated `micControlQueue` (serial, utility QoS) owns every blocking
   AVAudioEngine and CoreAudio call in the mic control path.
   `audioQueue` keeps exactly one job: moving buffers into the pipeline.
2. `handleEngineConfigChange` splits into three phases - snapshot on
   `audioQueue`, blocking work on `micControlQueue`, commit back on
   `audioQueue`. Only the middle phase can block, and nothing waits on it.
3. `configChangeGeneration` gains an in-flight flag. Three sources trigger a
   reinstall (notification, default-input listener, watchdog) and the work is
   now asynchronous, so overlapping runs are reachable in a way they were not
   before.
4. The stall monitors move off `audioQueue`. A `DispatchSourceTimer` scheduled
   on the queue it is meant to observe cannot fire while that queue is blocked,
   which is why the incident log has no drift lines for eleven minutes.
5. `fillGap` logs what it wrote, not what it was asked to write.

## Why the obvious alternatives do not work

- **Handle the config change on `.main`** (what the `swift-macos` skill's
  device-following snippet does). That moves a 683 s block onto the UI thread:
  the app freezes, `applicationShouldTerminate`'s 8 s budget is blown, and the
  writer never finalizes. Strictly worse than the status quo.
- **Give SCStream its own `sampleHandlerQueue`.** The right end state, and too
  large for this fix. `RecordingPipeline` is `@unchecked Sendable` with
  `nonisolated(unsafe)` state whose only safety argument is that
  `AudioRecorder`'s executor serializes both tracks. Split the queues and the
  shared session-start state and per-track cursors need real synchronization,
  and the compile-time story built on the actor executor has to be rebuilt.
- **Wrap the blocking call in a timeout.** Dispatch has no preemption; a
  blocked HAL call cannot be cancelled. A timeout can report the stall, never
  end it, and the queue stays blocked for exactly as long either way.
- **Fill the system-track gap afterwards.** Masks the symptom. The audio was
  dropped inside ScreenCaptureKit and never reached the process.

## Implementation

1. Add `micControlQueue` alongside `audioQueue` in `AudioRecorder`. It is not
   an actor executor - it is a plain serial queue for blocking calls, and
   nothing actor-isolated may be touched from it.
2. Split `handleEngineConfigChange` (`AudioRecorder.swift:786`):
   - **snapshot** (`audioQueue`): phase guard, generation check, `onContinuity`,
     capture the `AVAudioEngine` reference and the tap handler.
   - **blocking** (`micControlQueue`): `ObjCGetInputNode`, `ObjCRemoveTap`,
     `inputFormat(forBus:)`, format validation, `ObjCInstallTap`,
     `ObjCStartEngine`, the `auAudioUnit.deviceID` read and the CoreAudio
     property reads inside `queryMicLatencyOffset`. Every one of these can
     block on a wedged HAL; none of them touch `RecordingPipeline`.
   - **commit** (`audioQueue`): write `micLatencyOffset`,
     `micLatencyOffsetTicks` and `lastMicHostTime`, log the outcome, clear the
     in-flight flag.
3. Add the in-flight guard. `requestMicReinstall` returns early while a
   reconfiguration is running and records that another was asked for, so one
   follow-up run is scheduled on commit rather than a queue of them.
4. Move `startDriftMonitor` (`AudioRecorder.swift:977`) and the mic watchdog
   timer (`AudioRecorder.swift:929`) onto a monitor queue, reading the
   `lastMicHostTime` / `lastSystemHostTime` timestamps atomically. Add the
   system-side arm: `sys_age` past a threshold logs an error and routes a
   `RecorderFailure` so `AudioMonitor` can restart the stream, which is the
   recovery the mic has had since D12 and the system track has never had.
5. Fix the log in `fillGap` (`RecordingPipeline.swift:722`) to print
   `written * chunkSize / sampleRate` seconds, and have the caller
   (`RecordingPipeline.swift:560`) report the same number.

## Traps

- **`AVAudioEngine` is not `Sendable`.** Crossing to `micControlQueue` needs a
  `nonisolated(unsafe)` capture. The pattern already exists for `CMSampleBuffer`
  in `SCStreamProxy` (`AudioRecorder.swift:1098`); it is sound here for the
  same reason - the queue is serial and the engine is touched from nowhere
  else while the work is in flight - but it must be reviewed, not skimmed.
- **The watchdog re-arm currently rides a `defer` on `audioQueue`**
  (`AudioRecorder.swift:791`). Once the blocking work moves off-queue, that
  `defer` fires while the reconfiguration is still running. Without the
  in-flight guard from step 3, the 2 s watchdog would then request a fresh
  reinstall on every tick of a long reconfiguration.
- **`stop()` during an in-flight reconfiguration.** `stopMicCapture` runs on
  `audioQueue` and must not tear down the engine underneath the blocking
  phase. The phase check plus the generation guard cover the commit hop; the
  blocking phase must re-check `phase != .stopped` before installing anything.
- **Do not move the tap handler.** It already dispatches to `audioQueue`
  (`AudioRecorder.swift:660`), which is what keeps mic buffers serialized with
  SCStream buffers. That serialization is the invariant the pipeline's
  unsynchronized state depends on, and this fix must preserve it exactly.

## Testing

The hardware suite already runs on a CI image with two virtual audio devices.
Add a device-switch test: start a recording, switch the default input mid
recording, stop, and assert the **system** track duration is within 0.3 s of
wall clock. Today's code loses 0.5 s to 2.0 s on every switch measured, so the
test fails before the fix and passes after - the whole bug class, caught by one
assertion.

Keep the existing `AudioRecorderRaceTests` green: they cover start/stop races
against live ScreenCaptureKit and are the closest thing to coverage of the
teardown path this change touches.

## Out of scope

- **System-track gap fill.** Once the queue is decoupled, system audio stops
  only when SCStream itself stops, which the delegate already reports as a
  `RecorderFailure`. It is also a trap worth its own change: SCStream delivers
  Float32 stereo **non-interleaved**, while `makeSilentSampleBuffer`
  (`RecordingPipeline.swift:844`) builds interleaved packed LPCM with a single
  block buffer. Appending that to the system input is a source-format change
  mid-stream and the writer rejects it. Doing it right needs a
  `kAudioFormatFlagIsNonInterleaved` ASBD with a two-plane `AudioBufferList`.
- **A dedicated SCStream delivery queue**, for the reason given above.
- **The 683 s HAL stall itself.** It is a property of the reporter's device,
  not of this code. The goal here is to survive it with the system track
  intact, not to prevent it.

## Effort

About four hours for steps 1 to 3, half an hour for step 4, five minutes for
step 5, and two to three hours for the CI test. The risk is not complexity: it
is that this is `nonisolated(unsafe)` territory where a careless patch trades
silent data loss for a crash.
