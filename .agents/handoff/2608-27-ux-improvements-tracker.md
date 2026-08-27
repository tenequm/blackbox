# UX improvements tracker

Branch `feat/ux-improvements`, off `main` at `10d9184`.
Findings source: `docs/plans/2608-27-audit-findings.md`.

**This file is the reconciliation point.** Update the status column when
something lands, and never mark an item done without a commit SHA next to it.

Last updated: 2026-08-27, after commit `a15bff1`.

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
| B | Re-transcribe button (detail toolbar + row context menu) | todo |
| C | Transcript: selectable/copyable text, always-readable contrast, auto-scroll, speed control, h:mm:ss timestamps | todo |
| D | Scrubbing (`isDragging` never set) + rename `@FocusState` | todo |
| E | Menu bar: saving state, error badge instead of hijack, timer clip past 1h, `0:60` countdown, mic-grant branch, pause auto-record, reveal in Finder, accessibility label, icon width (crash risk C1) | todo |
| F | Toast click observer -> AppDelegate; quit-in-progress feedback | todo |
| G | Onboarding honors its permission results; re-openable; step indicator | todo |
| H | `Settings` scene + `.commands` (Cmd+, Cmd+Delete, Cmd+F) | todo |
| I | List: multi-select (already written, unreachable), search, date sections, export format + silent failure, delete consistency | todo |
| J | Accessibility sweep across all screens | todo |
| K | Settings content: consent sheet, cost, deletion wording, notifications naming, screen-recording request, key trim/debounce, model picker, storage stats refresh | todo |
| L | Speaker-index crash, plurals, ellipses, remaining polish | todo |
| M | Concurrent transcription queue (remove the global one-at-a-time + gate) | **planned** - `docs/plans/2608-27-concurrent-transcription.md`, 5 commits, not started |
| N | AEC: `Bundle.module` resolves to a path that does not exist in a shipped app. Fix or drop the feature | todo - user wants to reconsider dropping |

## Known-broken, decided later

- **AEC is broken for every user who is not the developer.** SPM's generated
  accessor looks for `Bundle.main.bundleURL/DTLNAecCoreML_DTLNAec256.bundle`,
  i.e. the `.app` root; the Makefile copies it to `Contents/Resources`. It has
  only ever worked via the accessor's hardcoded fallback to the developer's
  `.build` directory. Clicking the button on any other Mac is a `fatalError` on
  a background queue. Crash confirmed: `Blackbox-2026-08-27-182314.ips`.

## Data-loss items from the audit not yet scheduled

These are in the findings doc but not in the lettered list above. They are not
UX and should get their own branch unless they turn out to be one-liners.

- D2 stop-then-quit truncates the file (untracked stop tasks, `AudioMonitor.swift:278/335/649/673`)
- D3 AEC partial write poisons every downstream consumer
- D5 `RecordingMetadata` / `TranscriptDocument` have the missing-key hazard that
  `TranscriptionJob` was hardened against, and a rename then destroys the file
- D6 `LogFile.write` aborts the process on a full disk

## Verification still owed

- Full `make check` including the hardware suite - not run since `a15bff1`,
  because the user was recording. **Run before any PR.**
- Manual: click a "Recording Saved" toast and confirm the window opens. If it
  does not, item F's premise is confirmed.
