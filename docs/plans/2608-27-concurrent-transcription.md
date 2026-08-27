# Concurrent transcription jobs

Plan for replacing the single-slot job runner. Written 2026-08-27 against
`main` at `10d9184`; line numbers are from that commit.

## The design in five lines

1. `queue` / `activeDirectory` / `runTask` / `gateTask` become
   `jobs: [String: Task<Void, Never>]` keyed by recording-directory path. Every
   finished recording gets its own task.
2. The coordinator stays wholly MainActor-isolated. That is what makes N
   concurrent jobs safe with no locks: only the already-`@concurrent` service
   calls, the duration probe and the resume scan leave main.
3. One bounded stage: a MainActor counting gate (default 2) around `upload`,
   which is where `TranscriptionService.mix` actually lives. Polling, fetching
   and deletes are unbounded - that is the whole point.
4. `lastFinishedPath` becomes `finishCounts: [String: Int]`. It has to: two jobs
   finishing in adjacent main-actor turns let SwiftUI coalesce a single
   `lastFinishedPath`, and one detail view never reloads.
5. The recording gate is removed and replaced with `suspendNewJobs()` called
   from `applicationShouldTerminate`. Quit deferral was its only demonstrated
   value.

## Why the obvious alternatives do not work

- **A `@globalActor` or plain actor around the mix bounds nothing.** Actor
  isolation is mutual exclusion across *synchronous* regions; `mix` awaits
  `exporter.export`, which releases the actor and lets the next caller in.
  Worth writing down because it is the first thing anyone reaches for.
- **A bounded task group** needs all participants inside one scope with known
  membership at entry. Jobs arrive at arbitrary times from three call sites.
- **An `AsyncStream` worker pool** re-serializes the whole pipeline unless it
  carries slot requests with a reply continuation per item - which is a
  semaphore, built worse.

## The upload gate

MainActor state on the coordinator; no actor and no lock needed because the
coordinator's state machine already runs on main.

```swift
private struct UploadWaiter { let id: UUID; let continuation: CheckedContinuation<Bool, Never> }

@ObservationIgnored private var uploadSlotsInUse = 0
@ObservationIgnored private var uploadWaiters: [UploadWaiter] = []

/// True when the caller owns a slot and must release it. False means the wait
/// was cancelled and the caller must not proceed to upload.
private func acquireUploadSlot() async -> Bool { ... }

/// A waiter that has already been handed a slot is no longer in the array, so a
/// cancel landing after the hand-off is a no-op. That is what makes a double
/// resume impossible.
private func abandonUploadWaiter(_ id: UUID) { ... }

/// Hands the slot straight to the head waiter rather than decrementing, so the
/// count never dips and a job arriving between release and wake-up cannot jump
/// the queue.
private func releaseUploadSlot() { ... }
```

Bound of **2**, injected as `Dependencies.uploadConcurrency` so tests can pin
it. Honest basis: nothing is measured. What is known is that each concurrent
mix costs one full-size temp file plus one full-size multipart body, so peak
temp usage is linear in this number, and AAC encode goes through a shared
hardware path so raising it does not divide wall-clock by it. Two bounds disk
at four recording-sized scratch files while still overlapping one job's
transmit with another's encode.

Gating the mix alone would mean splitting `upload` into `mix` + `uploadFile`
across the protocol and moving temp-file ownership to the coordinator. Not
worth it: the `defer { removeItem(at: mixedURL) }` inside `upload` is what
keeps a recording-sized file from leaking.

## Consent: four re-check points become five

The new one is immediately after `acquireUploadSlot()`. A job can now block on
the gate behind up to N uploads, each minutes long; without a check there,
removing the recording gate would open a wait window with no consent check in
it - exactly what D14 exists to prevent.

## What must survive, and does

- The explicit-request-outranks-automatic downgrade stays **ahead** of the
  in-flight guard in `enqueue`. Only `guard activeDirectory?.path != key,
  !queue.contains(...)` becomes `guard jobs[key] == nil`.
- Every branch of `resumePendingJobs` is unchanged; the in-flight guard becomes
  one dictionary lookup and gets *more* important, not less.
- `releaseRemoteRecord` / `discardRemote` / `fail` / `drop` move untouched.
  `discardRemote`'s unstructured `Task` must stay unstructured - it does not
  inherit cancellation, which is why cleanup still runs when the job's own task
  was what got cancelled.
- The duration floor stays **before** the gate, so short recordings at resume
  are dropped without occupying a slot.
- The deleted-directory check before `document.save` stays where it is, and
  matters more with N jobs live.

## `defer { jobs[key] = nil }` goes inside `run`, not the task body

`run` is MainActor-isolated with no suspension between its terminal
`finish`/`drop`/`fail` and its return, so the defer fires in the same
main-actor turn as the terminal status write. Clearing from the task body
would put a suspension between "status is terminal" and "slot is free", and
the retry-after-error test would intermittently hit the occupied guard.
All thirteen exits funnel through one of those three calls.

Preserved wart, deliberately: cancel-then-immediately-retry is rejected until
the cancelled task unwinds. That is today's behaviour too.

## Quit

Nothing here joins `applicationShouldTerminate`'s 8s budget. In-flight jobs die
with the process and resume next launch.

The one thing the gate did usefully was defer at quit: today `isRecording` is
still true when the monitor reports the save, so `pump()` defers and only a
sidecar is written. Remove the gate naively and that job starts an upload the
process kill interrupts mid-flight - turning D14's documented idempotency
residual into a routine path. `suspendNewJobs()` covers it precisely: one
synchronous bool on main, fires only on quit.

Running jobs are deliberately **not** cancelled on suspend - cancelling would
`drop` them and delete remote artifacts for work that would otherwise resume.

## Recommendation on the recording gate: remove it

Its premise ("mixing must not compete with a live call for CPU or disk") is
reasoning, never measured - and `runAEC` already does a comparable decode/encode
pass on user demand with no gate at all, while a recording may be live. Keeping
it "for the mix only" would add a second, less legible source of stalling for a
hazard nobody has observed.

If measurement ever justifies it, the lever is `uploadConcurrency`: set it to 1
to restore single-mix behaviour without restoring the whole-pipeline stop.

## Test impact

34 of 39 pass unchanged. Two need only setup lines deleted (both hold on
main-actor turn ordering, not on the gate). Two assert serialization and get
rewritten:

- `"a second recording waits while the first is in flight"` becomes
  `"a second recording transcribes while the first is still polling"` - the
  direct regression test for the 25-minute delay.
- `"cancelling a queued job drops the audio a previous session uploaded"`
  becomes the same test against a job waiting for an upload slot.

One is deleted: `"transcription is held back while a recording is in progress"`.

New tests: concurrent completion while another polls; cancelling one job leaves
others running; resume starts every pending job; the upload limit holds;
consent withdrawn while waiting for a slot; per-recording finish counts; a
recording reported at quit writes its sidecar without starting; gate FIFO; a
cancelled waiter does not leak its slot.

Harness: drop `recordingActive`, add `uploadConcurrency`, and give the fake a
settable upload hold plus a concurrent-upload high-water counter. Note
`completionErrors` is a shared FIFO consumed by whichever job arrives first, so
no concurrent test may use it.

## Migration order - suite green after each

1. **Bound concurrent uploads.** Add the gate and the fifth consent check.
   `pump()` still serializes, so the gate is never contended and all 39 tests
   pass untouched.
2. **Report completion per recording.** `finishCounts` replaces
   `lastFinishedPath`. Indistinguishable while one job runs at a time, which is
   why it lands before the concurrency change rather than with it.
3. **One job per recording.** Delete the queue, add `jobs`, keep the recording
   gate as a per-job wait loop. This is the commit that fixes the reported bug,
   and the gate-dependent tests still pass because the gate still exists.
4. **Drop the gate, suspend at quit.** Delete the wait loop and
   `isRecordingActive`; add `suspendNewJobs()`.
5. **Rewrite D14 and the CLAUDE.md bullet.** "One job runs at a time" and "Jobs
   are held while a recording is active" both go; the consent list goes from
   four points to five; the idempotency residual gains a sentence about the
   resume fan-out.

Run `make check` after 1, 3 and 4. Nothing touches `AudioRecorder.swift`, so no
Bluetooth/HFP manual pass is triggered.
