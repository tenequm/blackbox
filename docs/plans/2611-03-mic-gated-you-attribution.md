# Mic-gated "You" attribution

Plan for labelling the local user's speech "You" in transcripts by using the
recording's own mic track. Written 2026-11-03 against `main` at `859bc42`. This
is the second draft, implemented on `feat/mic-attribution`: the first was reviewed adversarially by Codex
(gpt-6-astra), which returned "rework". Every change from that draft is a
finding of that review, and the measurements below are from it.

## Problem

Soniox diarizes the single mixed upload, so the local user is clustered
together with remote voices.

The sample is a 31-min Google Meet call with 7 people; ground truth is the Meet
transcript, labelled by signed-in account. On it:

- Soniox v6 found 4 speakers and v5 found 5.
- v6's speaker 2 is the local user merged with one remote person. The local
  user's mic is active for about 57% of speaker 2's tokens, and for 0-2% of
  every other speaker's.

The UI already renders speaker `-1` as "You" with the accent colour
(`MainWindowView.swift:1277`, `:1572`), and `clampSpeaker` reserves -1
(`TranscriptionService.swift:227`), but nothing produces it.

## Goal and scope

When enabled, relabel the tokens the local user spoke to `-1`, using the mic
and system tracks already on disk. The feature:

- adds no Soniox cost, no new dependency and no new permission;
- is off by default, behind a Settings toggle;
- is reversible and re-runnable without another remote request.

Out of scope:

- separating remote speakers from each other (the later on-device diarization work);
- correction UI;
- the first-token `language` bug (`TranscriptionService.swift:882` takes the
  first language-bearing token, so one misheard opening second labels a whole
  English call `zh`).

## Resolved before implementation

These decisions supersede anything in the sections below that disagrees.

1. **Tokens get their own sidecar, `transcript-tokens.json`.**
   - Why not inline: the recordings list decodes every `transcript.json` when it
     scans (`MainWindowView.swift:334`). Inlining about 7,000 tokens per
     31-minute call would make that scan decode megabytes of JSON.
   - Format: `TranscriptTokens { transcriptCreatedAt, tokens }`, written compact.
   - Matching: a tokens file is used only when its `transcriptCreatedAt` equals
     the document's `createdAt`. A later re-transcription, or one by an older
     app version, therefore never pairs with stale tokens.
   - In memory, `TranscriptDocument` carries the tokens as a transient field that
     is not encoded.
2. **`SpeakerAttribution` stores the constants, not the indices.**
   - Fields: `version`, `appliedAt`, `localTokenCount`, `micThresholdDb` and
     `systemQuietBelowDb`.
   - Re-running is deterministic from the tokens plus the audio.
   - Reverting needs only the tokens: they are regrouped with no local indices.
3. **One entry point: `TranscriptionCoordinator.reconcileAttribution(recordingDirectory:)`.**
   - What it does: brings a saved transcript in line with the setting. With the
     setting on, it attributes when the document has no current-version
     attribution. With it off, it reverts when one exists. Otherwise it does
     nothing.
   - When it is called:
     - after a job finishes;
     - from the detail view's `loadTranscript()`, on appear and on every
       `finishCount` change. A reconciled document makes it a no-op, so there
       is no loop.
   - It skips a recording while a transcription job is running for it.
   - It remembers ineligible recordings (path plus `createdAt`) in memory, so
     reopening one does not re-decode it.
4. **Jobs with no recorded `sourceAudio` are skipped.**
   - That covers jobs that were in flight before this ships, and transcripts
     written before it.
   - `sourceAudio` is set on the job just before `upload` and persisted with
     `fileId`. The coordinator copies it onto the document when it saves.
5. **The fixtures are a synthetic 2-track M4A written by the test.**
   - It is written with `AVAssetWriter`: a stereo 48 kHz AAC system input and a
     mono 48 kHz AAC mic input, filled with tone bursts at known times.
   - No checked-in fixture.
6. **Settings.**
   - The toggle "Label my voice as You" goes in the Transcription section,
     directly after "Transcribe recordings automatically".
   - It is not disabled when there is no API key, because it works on
     transcripts that already exist.
   - Caption: "Finds your own speech from your microphone track and labels it
     You. Experimental: most reliable with headphones."
7. **Track eligibility is read with async loads before the work hops queues.**
   - The `formatDescriptions` channel count and the track count are read with
     the async `load` API.
   - The decode then reopens the asset on the work queue, using AECProcessor's
     blocking `loadTracks` pattern.
8. **Frames are placed by absolute sample index.**
   - The index comes from each buffer's PTS, at 16 kHz with 320 samples per
     frame. A gap in the PTS leaves those frames unknown.
   - A frame is known when it received at least half its samples.

## Design

### 1. Persist the tokens; segments become a projection

One `originalSpeaker` per segment cannot undo attribution: adjacent tokens from
speakers 1 and 2 can both become -1 and merge into one segment. So the
transcript keeps the provider's raw result and derives segments from it.

- **Tokens.** `TranscriptDocument` gains `tokens: [TranscriptToken]?`, where
  `TranscriptToken` is a `nonisolated struct` holding `text`, `startMs`,
  `endMs` and `speaker`, and is `Codable` and `Sendable`. It holds what Soniox
  returned, translation tokens excluded, and is written once and never mutated.
- **Attribution record.** `TranscriptDocument` gains
  `attribution: SpeakerAttribution?`, which records:
  - `version`: the algorithm version, an integer;
  - `parameters`: the constants actually used;
  - `sourceAudio`: the file name the tokens' timeline belongs to;
  - `localTokenIndices`: indices into `tokens` that resolved to -1;
  - `appliedAt`.
- **Segments stay the display contract.** Every existing reader keeps working
  unchanged. They are rebuilt from `tokens` plus `attribution` by one pure
  function, `TranscriptDocument.project()`. With `attribution == nil`, that
  function produces exactly today's grouping.
- **Decoding tolerates bad optional fields.** `tokens` and `attribution` decode
  with `try?`, so a malformed optional field drops only itself, never the paid
  segments. The document decoder currently uses throwing `decodeIfPresent`
  (`TranscriptionService.swift:159`); the new fields must not.
- **Old transcripts are not attributable.** Transcripts written before this
  ship have no tokens. They stay readable but cannot be attributed, and the
  feature reports that rather than guessing from segment start times.
- **Older app versions.** An older Blackbox reading a new file ignores the
  unknown fields. Renames write `metadata.json`, not the transcript
  (`MainWindowView.swift:1281`), so only a re-transcription by an older version
  would drop the new fields. That is accepted, because the result is readable,
  though not lossless.

### 2. Attribution is optional enrichment after the paid save

The job loop today fetches, checks that the directory still exists, and saves,
all in the same main-actor turn (`TranscriptionCoordinator.swift:679-693`).
Inserting an await there would route a cancel into `failurePolicy`, whose
`.cancelled` branch drops the job and deletes the remote result, or would make
Cancel wait behind a long decode. So:

- **Job path: unchanged apart from the save.** `fetchTranscript` returns the
  document with `tokens` filled in. The coordinator saves it exactly as today,
  then calls `releaseRemoteRecord` and `finish(.completed)`. A transcript is
  never at risk because of attribution.
- **Enrichment: separate and best-effort.** After `finish`, if the setting is
  on and the recording is eligible (section 3), the coordinator starts a
  separate attribution task keyed by the recording path. The task:
  - runs the analysis off main (section 4);
  - re-checks that the directory and the transcript still exist, and that the
    tokens are the ones it analysed (compare `createdAt`);
  - writes `attribution`, re-projects the segments, saves, and bumps
    `finishCounts` so an open detail view reloads.
- **Enrichment never touches the paid job.** It never enters `failurePolicy`,
  never changes the job sidecar, and never sets a transcription status. A
  failure logs a warning and leaves the saved transcript as it was.
- **Cancellation:**
  - Recording deleted: `forgetDeletedRecording` cancels the task.
  - Quit: `suspendNewJobs` stops new enrichment from starting.
  - `applicationShouldTerminate` never waits for enrichment, because a killed
    enrichment loses nothing.
  - A thread-safe flag (`OSAllocatedUnfairLock<Bool>`), checked on the work
    queue between buffers and before queued work starts, makes cancel prompt.
  - The continuation resumes exactly once.
- **Re-run.** The same entry point re-attributes from the stored `tokens`. It
  runs when the toggle is switched on for an existing transcript that has
  tokens, and after a `version` bump. Switching the toggle off re-projects
  without `attribution` and clears it. That makes the kill switch real for
  transcripts already on disk.

### 3. Timeline and eligibility

The tokens' clock is the clock of the file that was uploaded, and that file is
not always `audio.m4a`. `RecordingStore.audioURL(in:)` prefers
`audio-processed.m4a` (`TranscriptionService.swift:94`), and AEC rebuilds each
track starting at sample zero, ignoring the original timestamps
(`AECProcessor.swift:287`, `:299`, `:407`).

- **Record the uploaded file.** `TranscriptionJob` records the file name it
  uploaded (`sourceAudio`) when the upload starts, so a resumed job knows too.
  `fetchTranscript`'s caller copies it into the document.
- **Eligible recordings (v1).** All of these must hold:
  - `sourceAudio == "audio.m4a"`, the raw capture;
  - the file has exactly 2 audio tracks;
  - track 0 is stereo and track 1 is mono, which is the v0.8+ writer order
    (`RecordingPipeline.swift:215`);
  - both tracks decode to non-empty audio.

  v0.7 recordings (both tracks mono), legacy 3-track recordings, and recordings
  transcribed from the processed file are skipped and logged. Track identity is
  never guessed from channel count alone.
- **Clock.** Place analysis frames by the decoded sample timestamps AVFoundation
  delivers for each track. There is no fixed offset: the 44 ms seen in FFmpeg
  is a decoder artifact, and AVFoundation delivers both tracks from 0. Mic
  latency (D9) and leading or gap silence are already baked into the file at
  record time (`AudioRecorder.swift:684`, `RecordingPipeline.swift:525`).

### 4. The analysis

The analysis is a `nonisolated` worker, `MicActivity`, in a new file
`Sources/MicActivity.swift`:

- It creates, loads and reads the `AVAsset` entirely on its own serial
  `DispatchQueue`. It never runs on the cooperative pool, because
  `copyNextSampleBuffer` blocks; this is the rule AECProcessor follows.
- Only a `Sendable` value type crosses the continuation. The review found that
  passing `[AVAssetTrack]` into the queue closure fails Sendable checking; the
  working shape was compiled and run under this target's flags.
- It returns frame energies, not PCM. A 2-hour call is about 6 MB of energies
  instead of about 900 MB of Float32 audio.

The numbers are defined exactly, so the result is reproducible:

- **Decode:** LPCM Float32, 16 kHz, through `AVAssetReaderTrackOutput` output
  settings. The mic is mono. For the system track, take the per-channel power
  and average it, rather than downmixing samples, because averaging samples can
  cancel opposite-phase stereo content.
- **Frames:** 320 samples (20 ms). Energy in dBFS is
  `10 * log10(meanSquare + 1e-12)`, floored at -120 dBFS. A missing or partial
  frame is unknown, never quiet.
- **Mic active:**
  - The mic threshold is the larger of the mic's 10th-percentile frame energy
    plus 25 dB, and -50 dBFS.
  - On the sample, the 10th percentile is about -94 dBFS, so the fixed -50
    floor decides. The adaptive branch is unvalidated, and the record stores
    which branch fired.
  - Smoothing, in this order: fill inactive gaps of 15 frames or fewer, then
    drop active runs shorter than 10 frames.
- **Echo gate:**
  - A mic-active frame is local only when the system frame is below the
    system's 10th-percentile energy plus 15 dB.
  - Digital silence gives a floor at -120 dBFS, so the gate stays finite.
  - Unknown system frames fail the gate.
- **Token rule:**
  - A token becomes local when at least 60% of its span, padded by 40 ms on
    each side, lies in local frames.
  - A zero-length token is judged on the padded window.
  - A token whose timing is malformed keeps its label.
- **No run-consistency pass.** The first draft's sandwich rule contradicted
  itself, and it changed six tokens on the sample.

On the sample, these constants move 944 tokens to -1: 939 of v6 speaker 2's
1,779 (53%), 5 from speaker 1, and none from speakers 3 and 4. The gate rejects
116 mic-qualified tokens. The local user's speech comes out as 57 "You"
segments; without the gate it is 37. Segments are not turns, so this is not a
precision figure, but it is why the feature ships off. The constants are a
reproducible baseline, not a validated tuning.

The pass took 1.7-1.8 s for 31 minutes on this machine, so roughly 7 s for a
2-hour call.

### 5. Setting

- **Toggle.** "Label my voice as You" in the transcription section of Settings,
  key `SettingsKeys.micAttribution`, default `false`.
- **Caption.** "Uses your microphone track to find your own speech. Experimental:
  works best with headphones."
- **Re-run trigger.** Switching it on re-attributes existing eligible
  transcripts lazily, when a transcript is next opened, not as a bulk job at
  toggle time.

## Known behaviour changes

- Speaker renames are keyed by provider id in `metadata.speakers`. Once the
  local user leaves speaker 2, a name the user gave speaker 2 lands on the
  remote person who remains. This is new with attribution. Test it, and note it
  in the setting's help text.
- A stored name for `-1` overrides "You", and renaming "You" renames every local
  segment. That is intended.
- Copy, text export and JSON export already go through the speaker-name helper
  (`MainWindowView.swift:1480`, `:1513`), so they follow automatically.
- Several people sharing one physical mic are all labelled "You".

## Tests

All hermetic, under `make test-unit`.

- **`MicActivity` on synthetic 2-track M4As written in the test:**
  - Mic-only bursts become -1.
  - Overlap with system audio keeps its label.
  - System-only audio keeps its label.
  - The same signal on both tracks at the same time gives no -1.
  - Antiphase stereo system audio still counts as active.
  - Digital-silence system audio gives a finite floor.
  - A single-track file, a 3-track file and a v0.7 mono+mono file are all
    skipped.
  - A corrupt file returns an error without throwing into the job.
- **Projection:**
  - With no attribution, the output equals today's grouping on the existing
    contract fixtures.
  - Tokens from two speakers that both become -1 merge, and clearing the
    attribution splits them back.
  - Malformed `tokens` or `attribution` JSON leaves the segments intact.
  - Old segment-only sidecars round-trip.
- **Coordinator, with an injectable attribution dependency and a fake that can
  block:**
  - The paid transcript is saved before enrichment starts.
  - Cancel while enrichment is queued or running leaves the transcript saved
    and the remote record released.
  - Deleting the recording mid-enrichment writes nothing.
  - `suspendNewJobs` prevents a start.
  - An enrichment save failure leaves the original transcript.
  - Two recordings finishing together each reload.
  - A processed-source job is skipped.
  - The toggle being off means no enrichment runs.
- **`TranscriptionServicing`:** it stays `nonisolated` with `@concurrent`
  requirements (AGENTS.md). `FakeTranscriptionService` returns tokens.

## Validation before default-on

The feature stays off by default until it is checked against hand-annotated
local speech on at least:

- a headset call;
- a laptop-speaker call (the echo case);
- a noisy-room call;
- a call where the local user talks over others (double-talk).

The numbers to report are local-token precision and recall, and the false "You"
rate on remote speech. Turn counts are not the measure.

## Files

- `Sources/TranscriptionService.swift`: the `TranscriptToken` and
  `SpeakerAttribution` types, `project()`, the fetch that keeps tokens, and the
  tolerant decoding.
- `Sources/MicActivity.swift` (new): the decode, energies and token rule.
- `Sources/TranscriptionCoordinator.swift`: `sourceAudio` on the job, the
  enrichment task, cancellation and re-run.
- `Sources/SettingsView.swift`: the toggle and key.
- `Sources/MainWindowView.swift`: lazy re-run on open; otherwise unchanged.
- `Tests/`: as above.
- `docs/specification.md`: a D14 note on enrichment and the token sidecar.

## Spike on five calls: the speaker-level rule

The word-level gate alone, as first implemented, split the local user into two
speakers on two-person calls. When "You" appeared it was right 89-98% of the
time, but about 30% of the user's speech time kept the provider's label: pauses
inside turns and double-talk.

**Method.**
- Calls: five real calls, with ground truth from the per-turn chat logs in
  `db-work/docs/chat-logs` and, for 2026-11-02, the Meet transcript.
- Scoring: a 0.25 s grid, with the best one-to-one mapping of labels to people.
- Bias: the chat logs were built on Blackbox's own Soniox segments, so they
  flatter Soniox's boundaries.

**Per-speaker evidence.** "Remote" means the mic is silent while the system
track is active.

| Provider speaker | Remote share |
|---|---|
| Only the local user (4 calls) | 2-13% |
| Local user merged with a remote voice (2026-11-02, v5 and v6) | 27-39% |
| Everyone else | 59-96% |

**Rule.** A speaker with at least 30% local and at most 20% remote tokens
becomes "You" whole, except its remote tokens.

**Results.** "Accuracy" is the share of grid points labelled with the right
person.

| Call | Word gate only | Speaker-level rule |
|---|---|---|
| 10-28, 2 people | accuracy 0.77, You recall 0.64 | accuracy 0.90, recall 0.88, precision 0.92 |
| 10-23, 2 people | accuracy 0.80, You recall 0.68 | accuracy 0.93, recall 0.93, precision 0.95 |
| 10-26, 7 people | accuracy 0.84 | accuracy 0.88, recall 0.95, precision 0.86 |
| 10-29, 6 people | accuracy 0.74 | accuracy 0.75, recall 0.85, precision 0.82 |
| 11-02, 7 people (merged speaker) | no change: falls back to the word gate, as intended | |

**FluidAudio, scored on the same calls, was not a consistent win.**
- Speaker count: right on 3 of 5 calls.
- One remote person was split into two on 10-23.
- 10-26 was under-counted, 4 speakers found for 6.
- Accuracy against the word gate ranged from -0.04 to +0.15.

It is parked.
