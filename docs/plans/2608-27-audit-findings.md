# Full audit, 2026-08-27

Ten parallel reviews of the codebase at `main` (`10d9184`), five on user
experience and five on engineering correctness. Findings are recorded here as
found; nothing below is fixed unless it says so. Line numbers are against
`10d9184` and will drift.

Verification status is stated per finding. **[verified]** means checked against
source or an SDK header in this session, not taken from a reviewer's report.
Anything needing hardware or a runtime observation says so instead of asserting.

## Status

All of this was fixed on `feat/ux-improvements`, which is PR #25:

**Fixed:** D1, D2, D3, D5, D6 (every data-loss item), C1, C3, T2, T5, T6, T7,
T8, T9, and the whole user-experience and accessibility sections.

**Not fixed, and deliberately out of scope for that branch** - these want their
own follow-up, roughly in this order:

- **P1** the waveform extractor: 0.5-1 GB per selection, uncancellable,
  unserialized, uncached. The largest single item left.
- **C4** the same extractor blocking cooperative-pool threads.
- **S1-S4** the silent-capture-failure set: mic start failure swallowed, denied
  mic producing a silent track, no detection of a flowing-but-silent system
  track, and SCStream error codes falling through to a non-restarting `.other`.
- **C2** `precondition` on a losing start/stop race.
- **C5** unbounded spin in AEC backpressure.
- **S6** Sparkle can relaunch mid-recording.
- **T1**, **T3**, **T4**, **T10-T14**, **P2-P11**.

---

# Data loss

## D1. `cancelWriting` deletes the recording, and the code treats that as success [verified] - FIXED

`RecordingPipeline.swift:338-357`

A five-second watchdog raced `finishWriting` and called `cancelWriting` on
timeout, on the assumption that the result is a truncated file. It is not.
`AVAssetWriter.h:365`:

> If an output file was created by the receiver during the writing process,
> `-cancelWriting` will delete the file.

`.cancelled` was then treated the same as `.completed`, so `stop()` returned the
directory, the HUD reported "Recording Saved", and transcription queued a
directory with no audio in it. Finalizing a long two-track recording writes
sample tables for hours of AAC, so exceeding five seconds on a loaded or
nearly-full disk is ordinary rather than exceptional.

Fixed: the timeout is gone and `finishWriting` is awaited to completion.
`movieFragmentInterval` already makes a hard kill recoverable, so there was
never anything to gain by cancelling. A slow finish is logged. `.failed` now
returns the directory only when audio actually survived.

## D2. Stop-then-quit truncates the file [verified]

`AudioMonitor.swift:278`, `:335`, `:649`, `:673`

All four stop paths nil the recorder and *then* launch an untracked
`Task { await recorder.stop() }`. `stopMonitoring()` awaits only
`autoRecorder`/`manualRecorder` - both nil by then - plus the two start tasks,
so `applicationShouldTerminate` replies while `finishWriting` is still running.

Stop a recording, quit within a second or two, and the file lands without a
`moov` atom. `savingCount` already tracks exactly this state for the UI; it is
simply never awaited.

Fix: hold the stop tasks in a set, and await them in `stopMonitoring()` after
the recorder awaits. Bounded by the same timeouts already in place.

## D3. AEC writes straight to its final filename with no fragment interval

`AECProcessor.swift:26`, `:109`, `:29`, `:43`

A quit during echo cancellation leaves a headerless `audio-processed.m4a`.
That file is then preferred by `RecordingStore.audioURL(in:)`, so it silently
becomes the transcription source (and gets billed), the export source, and the
playback source. `hasProcessed` goes true from a successful `fileSizeKey` stat,
which hides the AEC button, and `process` refuses to re-run because the file
exists. Only Finder recovers it.

Fix: write to a `.partial` name and `replaceItemAt` after `finishWriting`
reports `.completed`; sweep stale partials at launch.

## D4. A `.failed` writer leaves an orphan directory and reports nothing

`RecordingPipeline.swift:346-359`

On writer failure `stop()` returns nil without removing the directory, so there
is no notification, no HUD, no transcription - but the partial file stats fine
and does appear in the recordings list. The inverse of D1: the user has data and
was told the recording failed.

## D5. Adding a field to `RecordingMetadata` or `TranscriptDocument` orphans every existing file, and the next rename destroys it

`TranscriptionService.swift:6-33` (metadata), `:74-104` (transcript)

Both use synthesized `Codable`, which throws on a missing key, and both `load`
with `try?`. `TranscriptionJob` was deliberately hardened against this
(`TranscriptionCoordinator.swift:38-53`, with the reasoning written out); these
two were not.

The escalation is what makes it severe. `renameRecording`
(`MainWindowView.swift:244`), `saveTitle` (`:732`) and `saveSpeakerName`
(`:754`) all do `load(...) ?? RecordingMetadata(fresh)` and then atomically
write the reconstruction. One unreadable decode plus one rename permanently
loses the title, the creation date, every speaker name, and `trackCount`. The
transcript equivalent is a paid-for transcript vanishing, the user pressing
Transcribe, and the intact file being overwritten by a re-billed one.

Fix: hand-written `init(from:)` with `decodeIfPresent` for both, and make the
three rebuild sites distinguish "no file" from "file present but unreadable".

## D6. `LogFile.write` aborts the process on a full disk

`Log.swift:71-77`

`FileHandle.write(_:)` raises `NSFileHandleOperationException` on ENOSPC.
Nothing catches it, so the app dies with SIGABRT - during recording, because
`RecordingPipeline` only pre-checks free space at start. One-character fix:
`try? handle.write(contentsOf: data)`.

---

# Crash and hang risks

## C1. The menu bar label re-lays-out at 4-5 Hz with an oscillating width

`BlackboxApp.swift:48-69`, driven from `RecordingPipeline.swift:653`

The three waveform glyphs have different widths and the icon has no frame, so
the status item re-lays-out continuously for the whole recording. The
`swift-macos` reference documents this configuration as an intermittent
`EXC_BREAKPOINT` inside `-[NSWindow _postWindowNeedsUpdateConstraints]`. Under
`LSUIElement` the crash is silent: the icon disappears and the user goes on
believing the call is being captured.

The elapsed `Text` already carries a fixed 38pt frame while the icon does not,
which suggests this was hit once and half-fixed.

Fix: pin the icon's frame, and bucket the level in `@Observable` state so the
label only changes on a real transition.

## C2. `precondition` turns a benign start/stop race into a crash

`AudioRecorder.swift:168`

`stop()` in the `.notStarted` branch sets `phase = .stopped`; a `start()` that
then reaches the actor traps. Every other lifecycle interleaving in this actor
was made reentrancy-safe. `AudioMonitor` already handles `.cancelled` silently
on both start paths, so `guard ... else { throw RecorderError.cancelled }` is a
drop-in replacement.

## C3. `hasReplied` is a function-local, so a second terminate can double-reply

`BlackboxApp.swift:200-213`

A fresh flag per invocation. During the eight-second `.terminateLater` window
the menu bar is still interactive, so a second quit trigger re-enters and both
invocations can call `reply(toApplicationShouldTerminate:)`. Hoist to an
instance property and guard re-entry.

## C4. `WaveformExtractor` blocks cooperative-pool threads

`MainWindowView.swift:1104`, loop at `:1129`

`Task.detached` is the cooperative pool, and `extractSync` drains
`copyNextSampleBuffer` synchronously over a whole recording. This is the exact
hazard `AECProcessor.swift:13-20` documents in this codebase's own words and
solves with a dedicated queue. Nothing cancels the previous extraction, so
arrow-keying the list stacks them.

## C5. Unbounded spin in AEC backpressure

`AECProcessor.swift:247-250`

`usleep(10_000)` with no iteration cap; a writer stuck in `.writing` spins
forever and `isProcessingAEC` never clears. The underlying cause is
`expectsMediaDataInRealTime = true` (`:112`, `:116`) on an offline transcode -
setting it false lets `AVAssetWriter` apply real back-pressure.

---

# Silent failures

## S1. Mic capture failure is swallowed entirely

`AudioRecorder.swift:259-267`

Logged and ignored - `onFailure` never fires, so no error and no HUD. Because
`audioEngine` stays nil, the entire D12 recovery layer is inert: the watchdog
was never started, the default-input listener was never installed, and
`requestMicReinstall` bails immediately. The mic is dead for the whole call with
no retry path. The writer still has a mic input, so the file finalizes with a
valid empty second track.

Trigger: the input device is momentarily unavailable at call start - AirPods
mid-transport-flip, a USB interface still enumerating - which is exactly when
calls begin.

## S2. A denied mic grant produces a silent track rather than an error

`AudioRecorder.swift:546-554`. The auth status is read only for the log line.
AVAudioEngine on a denied input delivers zeros, so the stall watchdog - which
detects buffer *absence* - stays satisfied. Needs hardware verification of the
exact zero-buffer behaviour on macOS 26; the path is unguarded either way.

## S3. Nothing detects a flowing-but-silent system track, and the meter masks it

`AudioRecorder.swift:500-510`, `RecordingPipeline.swift:625-658`

`publishAudioLevel` publishes the max across both tracks, so a dead track 0 plus
a live mic reads as perfectly healthy. The documented degraded-TCC mode is
precisely the case where capture succeeds, buffers flow, RMS stays at `-inf`,
and no error is ever posted. `startDriftMonitor` is also gated on `micEnabled`,
so `sys_age` is not logged for mic-less recordings.

## S4. Half the SCStream error codes fall through to `.other`, which never restarts

`AudioRecorder.swift:514-527`, `:532-540`; `AudioMonitor.swift:689-706`

`-3804` and `-3805` (replayd crash, XPC drop - real events on a long call) and
`-3818` become `.other`, which the auto path treats as terminal. The rest of the
call is lost with the restart budget untouched. Separately `mappedStartError`
lacks `-3815`, the exact drift the reference warns about.

## S5. Keychain writes are unchecked

`SettingsView.swift:501-513`. Both `OSStatus` values are discarded and no
`kSecAttrAccessible` is set. A rejected save leaves the field showing the key,
"Verify Key" passing because it tests the in-memory string, and auto-transcribe
silently never firing.

## S6. Sparkle has no delegates

`BlackboxApp.swift:14-15`, `Info.plist`

Both delegates nil and `SUEnableAutomaticChecks` unset. Nothing gates a check,
download, or relaunch on `monitor.isRecording`, so an update accepted mid-call
terminates the app. All four hooks exist in the pinned Sparkle 2.9.6:
`updater(_:mayPerformUpdateCheck:error:)`,
`updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`,
`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`, and
`supportsGentleScheduledUpdateReminders`.

---

# Correctness

| # | Finding | Location |
|---|---------|----------|
| T1 | Mic resampling adds 0.044% of samples per buffer on non-integer ratios - about 1.5s of desync per hour. 44.1kHz interfaces affected; 24k/16k are exact ratios, which is why AirPods testing never caught it. Needs hardware verification | `RecordingPipeline.swift:781`, `:813-820` |
| T2 | The recording gate was a single blind 30s sleep with no early exit, and `reportRecordingSaved` fired before `updateAutoState` cleared `isRecording` - so every automatic job waited the full gate for a condition already false. **Fixed**: ordering swapped on both stop paths, gate is now a 2s re-ask | `AudioMonitor.swift:656`/`:658`, `TranscriptionCoordinator.swift:375` |
| T3 | Leading-silence fill is one-shot; the comment at `:735-737` claims callers reattempt, and they cannot - the branch is gated on `!nextExpected.isValid`, which is set unconditionally | `RecordingPipeline.swift:513-536` |
| T4 | `.displayLost` restarts with no rate limit. If `-3815` fires while a display is still enumerable, `waitForDisplay` returns immediately and the loop is hot, creating a directory per iteration | `AudioMonitor.swift:686-688` |
| T5 | Quit budget had zero headroom: 3s stream stop + 5s finish equalled the 8s allowance exactly, and two recorders stop serially. **Partly fixed** by D1 removing the 5s half | `BlackboxApp.swift:202` |
| T6 | Export silently exports the 16kHz mono AEC output. Playback has an Original/Processed picker; export has no choice | `MainWindowView.swift:150`, `:196` |
| T7 | Export to an existing file fails after the user agreed to replace it - `copyItem` throws on existing and NSSavePanel's Replace does not unlink | `TranscriptionService.swift:362`, `:368` |
| T8 | A failed trash is a silent no-op, but the transcription job was already cancelled and its remote artifacts deleted | `MainWindowView.swift:229-242` |
| T9 | Detail-view metadata is cached at `onAppear` and `.id(id)` does not change on rename, so a speaker rename reverts a sidebar rename | `MainWindowView.swift:391-395` |
| T10 | `RecordingPipeline.stop()` runs off `audioQueue` while the class comment claims all mutation happens on it. Currently safe only because `AudioRecorder` nils `self.pipeline` before the await - an undocumented invariant that `@unchecked Sendable` will never catch a regression against | `RecordingPipeline.swift:69-74`, `:301` |
| T11 | A hung `stopCapture` abandons a live SCStream; the log line acknowledges it and nothing acts on it | `AudioRecorder.swift:396-414` |
| T12 | Every start and restart re-runs `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)`, the slow variant, uncached - implicated in the D13 ghost-recording incident | `AudioRecorder.swift:433-434` |
| T13 | No `NSWorkspace.willSleepNotification` observer anywhere; sleep relies entirely on fragment headers | - |
| T14 | Everything logs `privacy: .public`, so call app names and exact call times reach the unified log and every sysdiagnose, then get re-exported by "Copy Debug Log" | `Log.swift:15`, `:21`, `:27` |

---

# Performance

| # | Finding | Location |
|---|---------|----------|
| P1 | Waveform extraction materializes the whole file as `[Int16]` - 0.5 to 1 GB for 90 minutes, ~1.5x peak during realloc, written twice. Uncancellable, unserialized, uncached | `MainWindowView.swift:614-626`, `:1104-1141` |
| P2 | The 10 Hz playback tick invalidates the whole detail view and rebuilds `Array(doc.segments.enumerated())` - about 10,000 tuple allocations per second on a long transcript, purely to move a highlight | `MainWindowView.swift:630-636`, `:830` |
| P3 | A display-sleep power assertion is held for the entire recording, including audio-only manual ones. Correctly balanced, but the panel is a laptop's largest single draw | `AudioRecorder.swift:453-465` |
| P4 | Drift logs every 5s forever and rotation only runs at launch. Measured: `drift:` is 2149 of 13,387 lines, and `blackbox.prev.log` reached 1.2MB against a 1MB cap | `AudioRecorder.swift:977-1019`, `Log.swift:49-59` |
| P5 | The 3s call-detection poll does 60-160 synchronous CoreAudio property reads on the main thread, forever, and takes the HAL global lock during exactly the device transitions this app cares about. Neither poll passes `tolerance:`, so they cannot coalesce | `AudioMonitorSupport.swift:181-192` |
| P6 | Peak disk is about 3x the recording. The mix scratch and its multipart copy coexist for the whole upload because the `defer` fires after the transfer completes | `TranscriptionService.swift:289`, `:378-381` |
| P7 | Gap fill allocates a format description and block buffer per 1024-sample chunk, synchronously, on the queue SCStream delivers system audio on. Observed running to completion (100 buffers) with no back-pressure break | `RecordingPipeline.swift:538-556`, `:673-728` |
| P8 | `AECProcessor` builds a `CMAudioFormatDescription` per chunk - about 168,000 create/release pairs on a 90-minute recording, for an invariant format | `AECProcessor.swift:284-293` |
| P9 | `checkDiskSpace` does a `statfs` on the audio queue every 30s; slow-to-hung on a network save directory | `AudioRecorder.swift:1023-1050` |
| P10 | Transcript JSON encode and write happen on MainActor at the end of every job; the read side is acknowledged as main-thread work and the write side is not | `TranscriptionCoordinator.swift:507` |
| P11 | `LogFile.export()` runs `OSLogStore.getEntries` plus two `queue.sync` blocks on the main thread from a button action | `Log.swift:113-132` |

---

# User experience

## The transcript is the product and it is the weakest surface

- Text cannot be selected or copied - every segment is wrapped in a `Button`
  (`MainWindowView.swift:949`) and `.textSelection` appears nowhere in the app.
  The only way to get words out is the JSON export.
- The whole transcript renders `.secondary` grey whenever playback is stopped
  (`:850`, `:986`), which is precisely the state in which people read.
- Playback never follows along - no `ScrollViewReader`, so the highlight leaves
  the screen after about thirty seconds and never returns (`:828`).
- No playback speed control anywhere - the single most-used control in every
  call-recording product.
- Timestamps use `m = total / 60` with no hour component (`:1000`), so a
  78-minute call reads "78:12" while the transport above it reads "1:18:12".
  The correct `formatTime` already exists eighty lines away.
- An unplayable audio file hides the transcript entirely (`:375`), losing the
  one artifact that survived.

## Scrubbing is broken, not merely imperfect

`isDragging` is declared (`:353`) and read (`:632`) but never assigned true, so
the 10 Hz observer overwrites the drag; and every `onChanged` tick fires a
zero-tolerance seek. The playhead stutters and snaps back under the cursor.

## Rename has no focus

Both rename paths (`:290`, `:426`) swap in a `TextField` with no `@FocusState`
anywhere in the app. Double-click, get a caret-less field, type, nothing
happens.

## Structural

- Settings is a tab inside a `TabView` wrapping a `NavigationSplitView`
  (`:14-21`). Cmd+, is dead in the window the user is looking at, because the
  only binding is on a menu item. There is no `.commands` block and no
  `Settings` scene anywhere in the app.
- No search, no date sections, no sort control. With 300 recordings the sidebar
  is a wall of near-identical titles.
- Multi-select is already written and unreachable: `revealInFinder`,
  `exportRecordings` and `deleteRecordings` all take `Set<String>`, and there is
  a complete multi-file export branch at `:201-226` that can never run, because
  the selection binding is a single `String?`.
- Transcript export fails silently (`:900-909` logs and swallows) and JSON is
  the only format offered.
- "All / System / App / Mic" and "Original / Processed" are engineer vocabulary.
  Nobody outside this repo knows "System" means the other people on the call.
- Delete is confirmed in the detail view and instant from the context menu.

## The menu bar lies about permission state - FIXED

`permissionNeeded` started false and was only ever set inside failure handlers.
The `CGPreflightScreenCaptureAccess()` result at `BlackboxApp.swift:113` was
used only to decide whether to show onboarding. A denied user saw a healthy icon
and a menu offering "Record Now" until the first recording failed.

Fixed: a `screenCaptureAccessGranted` dependency seeded at `startMonitoring` and
re-checked on the settings poll that already runs every five seconds.

## Menu bar, remaining

- No "saving" state - `isSaving` maps to the idle icon, so the glyph says
  "nothing happening" while the file is still being written.
- Errors hijack the recording icon (`:48`). `"Display slept - resuming
  recording..."` is a benign status that replaces the recording glyph with a
  warning triangle for ten seconds while recording continues fine.
- "Grant Microphone Access" (`:262`) is a dead button once denied.
  `SettingsView.swift:234-247` already handles this correctly.
- The elapsed timer clips past an hour (38pt frame versus `"1:02:33"`) and the
  grace countdown can render `"0:60"`.
- No way to pause auto-recording from the menu. Before a call you do not want
  recorded, the options are: open the window, find Settings, toggle, remember to
  toggle back. Under pressure people quit the app and forget to relaunch.
- No "Reveal Recordings in Finder", no global hotkey, no shortcut on Record Now.
- Icon weights are inverted: idle is the filled glyph, recording is the unfilled
  one.

## Quitting and onboarding

- Quitting mid-recording shows nothing for up to eight seconds. `LSUIElement`,
  so no Dock icon, menu already closed, stale icon. The natural read is "hung",
  and the natural response is Force Quit - the one action that corrupts the file
  this code is protecting.
- Onboarding's final step calls `CGRequestScreenCaptureAccess()`, discards the
  `Bool`, and closes the window regardless (`OnboardingView.swift:135-142`).
  Deny it, or arrive already-denied where no prompt appears, and setup
  "succeeds". Grant it and nobody mentions macOS needs a relaunch.
- The mic and notification steps discard their results too (`:124-134`).
- Onboarding can never be re-opened, and `hasCompletedOnboarding` is written and
  never read.
- The notifications step promises alerts on start and save. Those are in-app HUD
  panels; the notification permission is used for exactly one message.

## The "Recording Saved" toast click may be dead

`BlackboxApp.swift:316-322` attaches the observer via `.onReceive` on the Quit
button inside `MenuContent`, which with `.menuBarExtraStyle(.menu)` only exists
while the menu is open - and the toast fires when it is closed. Not confirmed at
runtime. Needs one manual test: click a saved toast and see whether the window
opens.

## The HUD swallows clicks

`RecordingHUD.swift:80-84`, `:122-131`. A non-click-through panel parked exactly
where Notification Center banners appear, for up to ten seconds, with no close
affordance and no Escape handling. It can cover a fullscreen call app's
top-right controls, and clicks in that region do not reach the app underneath.

## Settings

- Auto-transcribe fires on a bare toggle with no confirmation
  (`SettingsView.swift:333-339`). One click commits every future call - including
  audio of people who never consented - to a third party, and starts spending
  money.
- The disclosure does not say both sides of the call are uploaded, or that the
  processed file is preferred when present.
- "Blackbox deletes it from Soniox" is stated as fact; deletion is best-effort
  and gives up permanently when the key is gone. Nothing surfaces
  `awaitingRemoteDelete`.
- No cost information anywhere for a per-minute paid API, no usage counter, no
  spend cap, and no maximum-duration cap.
- The "Notifications" section does not control notifications **[verified]** -
  the three toggles gate the in-app HUD (`AudioMonitor.swift:832-843`), and the
  app's only real system notification, the permission-lost alert, has no toggle
  at all.
- The Screen Recording "Fix" button never requests the permission
  (`:220-229`); the Microphone row right below it does it correctly.
- Changing the save folder silently strands every existing recording and any
  in-flight job.
- The API key is rewritten to the Keychain on every keystroke (`:57-67`) and is
  never trimmed, so a pasted key with trailing whitespace fails with an opaque
  401.
- "Model" is a free-text field wired straight to the API (`:326-331`); a typo is
  a terminal failure per recording, after the upload has been paid for.
- `autoTranscribe` stays on when the key is removed - only `.disabled`, so it
  still reads "on" while nothing happens.
- Storage stats are computed once with a bare `.task` and go stale (`:73-75`).
- The Excluded Apps list does synchronous disk I/O inside `body` (`:148-155`).
- "Debug" is shown to everyone, in developer language, and "Open Log File"
  actually opens the directory.

## Accessibility - the app is not operable with VoiceOver

`rg accessibility Sources/` returns exactly one hit, an `NSAccessibility.post`
in the HUD. There is no `.accessibilityLabel` anywhere.

- Four icon-only toolbar buttons in the detail view carry `.help()` and nothing
  else (`:461`, `:469`, `:484`, `:491`). `.help()` is a hint, not a name.
- The three transport buttons have neither (`:555`, `:563`, `:571`), and
  `.buttonStyle(.plain)` strips the focus ring.
- The waveform is a bare `Canvas` (`:1042`) - invisible to VoiceOver, and its
  only seek affordance is a drag gesture, so scrubbing is mouse-only.
- Both segmented pickers are declared `Picker("")` (`:528`, `:538`), which is no
  accessibility name rather than a hidden one.
- Onboarding step changes are never announced and there is no position
  indicator.
- Permission rows convey state through an unlabeled icon and three identical
  "Fix" buttons.
- "1 recordings" in three places; no string catalog exists.
- Durations are hand-rolled `String(format:)` everywhere, so non-Latin-numeral
  locales get Western digits and VoiceOver reads "0 colon 15".
- Several hardcoded `.frame(width:)` calls clip at accessibility text sizes
  (`:533`, `:544`, `:974`, `:982`).
- Reduce Motion is consulted nowhere.
- Active-versus-inactive transcript segments are signalled by colour and an 8%
  tint, which Increase Contrast does not strengthen.
- The speaker palette is hardcoded system colours as small text; several fall
  under 4.5:1.
- `speakerColors[segment.speaker % 6]` crashes on a negative speaker index from
  a hand-edited or corrupted sidecar.

---

# Verified clean

Worth recording so nobody re-audits them.

- **All seven `assumeIsolated` sites are correct.** Each follows a hop onto
  `audioQueue`, and the CoreAudio listener at `:877` is registered with
  `audioQueue` directly. One fragile-but-correct detail: in
  `SCStreamProxy.stream(_:didOutputSampleBuffer:of:)` the `guard type == .audio`
  runs *before* `assumeIsolated`, and that ordering is load-bearing, because the
  proxy is registered on two different queues.
- **`NotificationCenter.addObserver(queue: nil)` at `:616` is safe** - the block
  is `NS_SWIFT_SENDABLE`, so it is imported `@Sendable` and is nonisolated.
- **`AudioRecorder` start/stop reentrancy** is the reference pattern implemented
  properly: `cancelRequested`, `checkAlive()` after every await, take-and-nil in
  `cleanupPartialStart()`, every step idempotent.
- **`AECProcessor` does not self-deadlock** - both blocking calls block
  `workQueue` while completions arrive on AVFoundation-internal queues.
- **`TranscriptionService`** - all five protocol requirements and every
  implementation are `@concurrent`; nothing heavy remains on MainActor there.
- **Path handling is clean.** Every path-keyed comparison in the codebase was
  checked, and both `contentsOfDirectory` calls are the `atPath:` form. The
  `RecordingStore.directories(in:)` discipline holds everywhere, including
  against the trailing slash `pickFolder` stores.

Also worth knowing: the three `EXC_BAD_ACCESS / SIGKILL (CODESIGNING)` reports
in `~/Library/Logs/DiagnosticReports/` are from `make install` replacing the
bundle under the running app, not a product bug. They do show that SIGKILL is
absent from the watchdog's reportable set, so force-quits and bundle
replacements are recorded as clean exits.
