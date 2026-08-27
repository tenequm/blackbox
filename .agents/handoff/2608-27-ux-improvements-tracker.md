# UX improvements tracker

Branch `feat/ux-improvements`, off `main` at `10d9184`.
Findings source: `docs/plans/2608-27-audit-findings.md`.

**This file is the reconciliation point.** Update the status column when
something lands, and never mark an item done without a commit SHA next to it.

Last updated: 2026-08-27, after commit `fbe1df2`. All lettered tasks A-N are done.

## Rules for working this list

- Work top to bottom. Do not skip ahead because something looks quick.
- `make test-unit` is safe at any time (hermetic, ~14s, no devices, no bundle).
- `make check` / `make test` seize the default audio devices and launch a real
  app bundle. **Never run them while the user is recording.** Ask first.
- `make install` replaces the running app. Same rule.
- One commit per lettered task, so a bad one can be reverted alone.

## Status

| # | Task | Status |
|---|------|--------|
| A | Land in-flight work: cancelWriting data loss, permission truth, 30s gate ordering, status enum + real progress, cancel state | **done** `a15bff1` |
| B | Re-transcribe button (detail toolbar + row context menu) | **done** `9ebcc0c` |
| C | Transcript: selectable/copyable text, always-readable contrast, auto-scroll, speed control, h:mm:ss timestamps | **done** `952091a` |
| D | Scrubbing (`isDragging` never set) + rename `@FocusState` | **done** `952091a` + `6f53333` |
| E | Menu bar: saving state, error badge instead of hijack, timer clip past 1h, `0:60` countdown, mic-grant branch, pause auto-record, reveal in Finder, accessibility label, icon width (crash risk C1) | **done** `6f53333` |
| F | Toast click observer -> AppDelegate; quit-in-progress feedback | **done** `6f53333` - also HUD click-through, screen choice, VoiceOver announcement, terminate double-reply, `processRunning` timing |
| G | Onboarding honors its permission results; re-openable; step indicator | **done** `4ee2160` |
| H | `Settings` scene + `.commands` (Cmd+, Cmd+Delete, Cmd+F) | **done** `4ee2160` |
| I | List: multi-select (already written, unreachable), search, date sections, export format + silent failure, delete consistency | **done** `4ee2160` |
| J | Accessibility sweep across all screens | **done** `c46e90d` |
| K | Settings content: consent sheet, cost, deletion wording, notifications naming, screen-recording request, key trim/debounce, model picker, storage stats refresh | **done** `62174ea` |
| L | Speaker-index crash, plurals, ellipses, remaining polish | **done** `952091a` + `c46e90d` |
| M | Concurrent transcription queue (remove the global one-at-a-time + gate) | **done** `998c8f2` - verified red-first |
| N | AEC: `Bundle.module` resolves to a path that does not exist in a shipped app | **fixed** `cc4bf12` - resolves the bundle itself, writes atomically, reports failures. Keeping the feature is now a product call, not forced by breakage |

## Known-broken, decided later

- **AEC is broken for every user who is not the developer.** SPM's generated
  accessor looks for `Bundle.main.bundleURL/DTLNAecCoreML_DTLNAec256.bundle`,
  i.e. the `.app` root; the Makefile copies it to `Contents/Resources`. It has
  only ever worked via the accessor's hardcoded fallback to the developer's
  `.build` directory. Clicking the button on any other Mac is a `fatalError` on
  a background queue. Crash confirmed: `Blackbox-2026-08-27-182314.ips`.

## Data-loss items from the audit

All four landed here rather than on a separate branch - each turned out small,
and three of them were reachable from the same code the UX work touched.

- D1 `cancelWriting` deleted the recording and reported success - `a15bff1`
- D2 stop-then-quit truncated the file (untracked stop tasks) - `fbe1df2`
- D3 AEC partial write poisoned every downstream consumer - `cc4bf12`
- D5 `RecordingMetadata` / `TranscriptDocument` missing-key hazard - `fbe1df2`
- D6 `LogFile.write` aborted the process on a full disk - `fbe1df2`

Hit in the field during this session, and now fixed: the AEC crash left
zero-byte `audio-processed.m4a` files in two of the user's recordings, and
because `audioURL(in:)` prefers the processed file those recordings reported
"Could not load audio: Cannot Open" with 19 MB and 29 MB of intact audio beside
them. The empty files were removed by hand; `isUsable` now means "has bytes"
everywhere, so an empty file can never outrank a working recording again.

## Verification still owed

- Full `make check` including the hardware suite - not run since `a15bff1`,
  because the user was recording. **Run before any PR.**
- Manual: click a "Recording Saved" toast and confirm the window opens. If it
  does not, item F's premise is confirmed.
