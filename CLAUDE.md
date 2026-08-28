# Blackbox

macOS menu bar app that auto-records call audio. Detects calls via CoreAudio per-process audio state polling. Captures system audio via display-wide SCStream (ScreenCaptureKit) and mic via AVAudioEngine as independent pipelines.

## Project Structure

```
Package.swift                              - SPM manifest, macOS 26.1+, Swift 6.2
Sources/
  BlackboxApp.swift                        - @main App, MenuBarExtra, Window scenes, AppDelegate
  AudioMonitor.swift                       - @Observable: call detection (polling), auto/manual recording lifecycle
  AudioMonitorSupport.swift                - RecorderSession protocol, AudioMonitorDependencies (DI), factory types
  AudioRecorder.swift                      - SCStream (system audio) + AVAudioEngine (mic), dual-track capture
  RecordingPipeline.swift                  - AVAssetWriter management, gap filling, tail padding, audio level metering
  AECProcessor.swift                       - DTLN-aec CoreML post-processing: echo cancellation on mic track
  TranscriptionService.swift               - Soniox stage-level client (upload/create/poll/fetch), TranscriptDocument sidecar
  TranscriptionCoordinator.swift           - App-level transcription: auto-trigger, one independent job per recording, resumable job sidecar
  BlackboxTestMode.swift                   - Test mode flags (--ui-test-mode), IPC types for smoke tests
  BlackboxTestController.swift             - File-based IPC controller for smoke test automation
  MainWindowView.swift                     - Main window: Recordings tab (NavigationSplitView list + detail) and Settings tab
  SettingsView.swift                       - Settings UI, defaults constants
  OnboardingView.swift                     - First-launch onboarding: permissions walkthrough
  RecordingHUD.swift                       - Floating NSPanel toast (top-right); the save toast opens the main window when clicked
  Log.swift                                - OSLog + file logging, debug export
Info.plist                                 - LSUIElement, NSAudioCaptureUsageDescription, NSMicrophoneUsageDescription
Makefile                                   - build, bundle, dmg, release, install, run, format, format-check, test, check, smoke, clean
.github/workflows/ci.yml                   - CI on macos-26: lint, full test suite, release-please, DMG publish
.github/workflows/release-note.yml         - Lints PR title + `## Release notes` section (they become the changelog)
.github/actions/signed-bundle/             - Imports the Developer ID cert and builds a signed .app
.github/actions/grant-recording/           - Seeds Screen Recording + Microphone into the TCC databases
.github/cliff.toml                         - git-cliff config; owns CHANGELOG.md and the release body
.github/release-please-config.json         - Version/tag/release-PR automation; Info.plist is the version file
.github/scripts/                           - make-appcast, bump-build-number, bump-cask, release-note-from-pr
Tests/
  BlackboxTests.swift                      - PCM conversion, AEC processing, gap filling, resample tests
  AudioMonitorIntegrationTests.swift       - AudioMonitor integration tests with fake dependencies
  RecordingPipelineIntegrationTests.swift  - RecordingPipeline file output, gap fill, tail padding tests
  AudioRecorderRaceTests.swift             - Start/stop race tests (one reaches live SCK, gated on the permission being granted)
  TranscriptionCoordinatorTests.swift      - Trigger decision, queueing, retry/failure, cancel, launch resume (fake Soniox client)
  SonioxContractTests.swift                - Real client against a loopback HTTP stub speaking Soniox's documented wire format
  HardwareSmokeTests.swift                 - End-to-end smoke test via real app bundle (hardware-gated)
  TestSupport.swift                        - TestClock, FakeHUD, MonitorHarness, BlackboxSmokeClient
  Fixtures/Recordings/                     - Reference recordings for AEC regression tests
.agents/skills/
  release-dmg/SKILL.md                     - full release pipeline (not model-invocable; read the file directly)
```

## Build & Run

```sh
make build      # swift build -c release
make bundle     # build + create .app bundle + codesign
make dmg        # bundle + create DMG with Applications symlink
make release    # dmg + notarize + staple
make install    # bundle + copy to /Applications
make run        # bundle + open .app
make test       # bundle + ALL tests including the hardware suite (~80s)
make test-unit  # hermetic subset only, no bundle/permissions/devices (~14s)
make check      # format + build + test (full validation)
make smoke-test # alias for test
make smoke      # alias for test
make format     # swift-format --recursive Sources/ Tests/ --in-place
make clean      # remove build artifacts
```

## Code Quality

### Compiler settings (Package.swift)
- `.swiftLanguageMode(.v6)` - strict concurrency, data race safety at compile time
- `.defaultIsolation(MainActor.self)` - all types MainActor by default
- `.treatAllWarnings(as: .error)` - zero warnings policy

### Formatting
- `swift-format` (Apple's formatter, installed via Homebrew)
- Run `make format` before commits
- 2-space indentation (swift-format default)

### No external linters needed
The Swift 6 compiler with strict concurrency + warnings-as-errors catches more real bugs than SwiftLint. swift-format handles style consistency.

## Testing

- **Framework**: Swift Testing (built into Swift 6.0+ toolchain)
- **Run**: `make test` or `swift test`
- **Test target**: `BlackboxTests` in `Tests/` directory
- **Isolation**: Same `defaultIsolation(MainActor.self)` as production code
- Tests find Testing.framework via the xcode-select'd toolchain; do NOT add CLT framework search paths to Package.swift (a version-mismatched CLT breaks every @Test macro with sourceLocation/sourceBounds errors)

### Test categories
- **Unit tests** (`make test-unit`): PCM conversion, gap filling, resample, AEC processing, RecordingPipeline integration. Run without special permissions.
- **AudioMonitor integration tests** (`make test-unit`): Use `MonitorHarness` with `TestClock`, `FakeHUD`, and `TestRecorderFactory` to test call detection, auto/manual recording lifecycle, continuity events, and restart budgets - no real audio hardware needed.
- **Hardware smoke tests** (`make test`): Launch the real `.app` bundle, drive it via file-based IPC (`BlackboxTestController`), record real audio, verify output file structure. Require System Audio Recording + Microphone permissions; `BlackboxSmokeClient.init` fails with the sentence that fixes it if either is missing.

`make test` runs everything, locally and in CI alike - there is no CI-only subset to drift out of sync. CI gets there by importing the Developer ID certificate and writing the two grants straight into the TCC databases (`.github/actions/grant-recording`); hosted runner images ship with SIP disabled and permit that, which is the only reason a headless machine can run this suite. The grant is keyed on the bundle's designated requirement, so it must be signed with the real certificate - an ad-hoc cdhash changes every build and would never match twice.

`make test` takes a `lockf(1)` lock on `/tmp/blackbox-smoke.lock`: two concurrent runs fight over the default audio devices and fail each other spuriously. `make test-unit` deliberately does not.

The only path no runner can cover is Bluetooth/HFP renegotiation - the runner's two virtual devices exercise the device-switch code, but not the HFP path. Check that by hand on real hardware when `AudioRecorder.swift` changes.

### Test mode infrastructure
The app supports `--ui-test-mode` for smoke tests. `BlackboxTestMode` parses CLI flags, `BlackboxTestController` polls `command.json` and writes `state.json` for IPC. `BlackboxSmokeClient` (in TestSupport.swift) drives the app from the test process.

## Logs

App logs: `~/Library/Logs/Blackbox/blackbox.log`
Crash reports: `~/Library/Logs/DiagnosticReports/Retired/Blackbox-*.ips`

## Pre-Release Checklist

Most of this is now enforced by CI on every PR - `make check` and the full
hardware suite both run there. What remains is what no runner can do:

1. **Automated (CI)**: `make check` plus the hardware suite, on every PR
2. **Bluetooth/HFP**: when `AudioRecorder.swift` changes, run `make test` on real
   hardware with AirPods connected - the runner's virtual devices exercise the
   device-switch code but not HFP renegotiation
3. **Manual smoke test**: `make install && open /Applications/Blackbox.app`
4. **Verify permissions**: First recording should prompt for System Audio Recording permission
5. **Test auto-recording**: Start any call (Zoom, Meet, etc.) - recording should start when microphone becomes active
6. **Test manual recording**: Menu > Record Now - should record and stop cleanly
7. **Test graceful quit**: Quit via menu while recording - file should be complete (not corrupted)
8. **Test settings**: All settings persist across restart, changes take effect within 5 seconds
9. **Check output files**: M4A files in ~/Library/Application Support/Blackbox/Recordings/, named with timestamp + app name, playable in QuickTime

## Release Process

Releases are automated. Land work on `main` with a Conventional Commits PR title
and a `## Release notes` section in the PR description; release-please keeps a
release PR open with the next version, and merging it does everything else.

```
PR merged to main
  -> release-please opens/updates the release PR (version, Info.plist, tag)
  -> release-changelog regenerates CHANGELOG.md + bumps CFBundleVersion on that branch
  -> you merge the release PR
  -> CI: signed build -> DMG -> notarize -> staple -> Gatekeeper check
        -> Sparkle-signed appcast.xml -> GitHub release -> Homebrew cask bump
```

`.github/workflows/release-note.yml` lints the PR title and the `## Release
notes` section on every PR, because both become the changelog and the release
body. It also catches a release-please parser bug: a body line starting `word(`
whose paren does not close on the same line is read as `type(scope`, and the
commit is SILENTLY DROPPED - the release is skipped with CI green
(googleapis/release-please#2564).

git-cliff owns `CHANGELOG.md` and the release body; release-please runs with
`skip-changelog: true` so the two never write the same file. The
`release-changelog` job is gated on *an open release PR existing*, not on
release-please having just changed one: keyed to the action's `pr` output it got
exactly one attempt per release, because every later push logs "PR #N remained
the same" and emits nothing - so a failed run could never be retried, and 0.9.4
reached a mergeable state with no changelog and an unbumped `CFBundleVersion`.
It also generates from **main**, not from the release branch: release-please
rebuilds that branch only when the files it writes change, so between version
bumps the branch keeps an older base with an older `cliff.toml`, and generating
there would reproduce that snapshot and omit every commit landed since. The
pending version therefore comes from the branch's manifest, not main's.

**`RELEASE_PLEASE_TOKEN` is optional but load-bearing.** Both the release-please
action and the changelog push fall back to `GITHUB_TOKEN`, which makes the actor
`github-actions[bot]` - and a repo whose contributor-approval policy has never
seen a merged bot PR gates every workflow on that PR, so the release sits at "2
workflows awaiting approval" with nothing red. The changelog job emits a
`::warning::` when the secret is absent, so the cause is visible in the run
rather than a mystery. The same shape is documented in `glim-sh/cuttle`, whose
`ci.yml` this one is derived from. The changelog entry
is rendered from squash-commit bodies, and
`.github/scripts/release-note-from-pr.sh` refetches the note from the PR when a
squash landed without one. That script must stay executable - git-cliff reports a
failed `replace_command` as a WARN and silently drops the commit from the entry.

**Info.plist is the single source of truth for the version.** The Makefile reads
`VERSION` from it with PlistBuddy, so the two can no longer drift. release-please
updates `CFBundleShortVersionString` via the `x-release-please-version`
annotation on that line. `CFBundleVersion` is a separate monotonic integer that
release-please cannot own; `.github/scripts/bump-build-number.sh` derives it from
the last release tag, which makes re-runs idempotent. Sparkle compares
`CFBundleVersion` to decide whether an update exists, so a value that ever goes
backwards silently stops updates for everyone already on the higher number.

Required repository secrets: `APPLE_P12_BASE64`, `APPLE_P12_PASSWORD` (Developer
ID, also needed by CI tests for TCC seeding), `APPLE_ASC_KEY_P8`,
`APPLE_ASC_KEY_ID`, `APPLE_ASC_ISSUER_ID` (notarization), `SPARKLE_PRIVATE_KEY`
(appcast signing), and `HOMEBREW_TAP_TOKEN` (cask bump; the step is skipped
rather than failed when it is absent). The Developer ID certificate and ASC key
live in the 1Password item `pond-apple-ci-signing`; the Sparkle key is backed up
as `blackbox-sparkle-ed25519-private-key`. Losing the Sparkle key is
unrecoverable - its public half is baked into every shipped copy.

`make release` still works locally and falls back to the `blackbox` keychain
profile when the ASC environment variables are absent. It gates on the
notarization JSON `status`, because `notarytool submit --wait` exits 0 even when
the notary returns `Invalid`.

The cask keeps `auto_updates true`: Sparkle self-updates the app, so plain
`brew upgrade` intentionally skips it, and removing the flag would let a lagging
cask downgrade a Sparkle-updated install.

## Key Architecture Decisions

- **Polling-only call detection** drives recording lifecycle. Every 3 seconds, CoreAudio Swift wrappers (`AudioHardwareSystem.shared.processes`) enumerate processes with BOTH `isRunningInput` AND `isRunningOutput` (filtering out own PID). Input+output check identifies actual calls, filtering out dictation/Siri/voice memos. No CoreAudio property listeners - polling-only eliminates ~140 lines of listener management code.
- **SCStream system audio capture**: Single display-wide `SCStream` (ScreenCaptureKit) captures the OS-composited audio mix, excluding own PID via `excludesCurrentProcessAudio = true`. Video throttled to 2x2 at 1 fps - `minimumFrameInterval` is a *minimum interval*, so a near-zero value (e.g. `1/Int32.max`) means maximum frame rate, not none (issue #17). The ignored `.screen` output is subscribed on its own queue, otherwise SCStream logs a dropped frame per video frame. `SCStreamOutput` callback delivers stereo 48kHz Float32 CMSampleBuffer on `audioQueue` and is appended **directly** to a stereo 128 kbps AAC writer input (v0.6.0 parity) - no PCM round-trip, no downmix. `SCStreamDelegate.didStopWithError` maps NSError codes (−3801 permission, −3802/−3821 stopped) to `RecorderFailure`. Requires Screen Recording permission (on macOS 26.1+, this also grants audio capture).
- **AVAudioEngine mic capture**: Independent mic pipeline via `inputNode.installTap()`. Can fail without affecting system audio. Device following via `AVAudioEngineConfigurationChange` notification (reinstalls tap, sub-second gap, same file). Device latency offset (D9) applied as PTS shift to align mic with system audio.
- **AudioRecorder is an `actor` with custom `DispatchSerialQueue` executor.** All actor-isolated state runs on `audioQueue`. SCStream and AVAudioEngine tap callbacks dispatch to `audioQueue` and use `assumeIsolated` to bridge into actor isolation. No `nonisolated(unsafe)` needed.
- **RecordingPipeline** (`@unchecked Sendable`) handles AVAssetWriter management, gap filling, tail padding, and audio level metering. Extracted from AudioRecorder for testability. All access serialized by AudioRecorder's `audioQueue` - the pipeline has no internal synchronization. `nonisolated(unsafe)` state is safe because AudioRecorder guarantees single-threaded access.
- **AudioMonitor dependency injection**: `AudioMonitorDependencies` struct injects all external dependencies (recorder factory, HUD, settings, clock, sleep, process query). Enables deterministic testing via `MonitorHarness` with `TestClock` and `TestRecorderFactory`. `RecorderSession` protocol abstracts over `AudioRecorder` for test doubles.
- **2-track M4A**: Track 0 = system audio (2ch stereo 48kHz 128 kbps AAC, SCStream buffers appended directly). Track 1 = mic (1ch mono 48kHz 64 kbps AAC, resampled/downmixed via `resampleToMono48k`). Session starts on whichever track delivers the first sample. Gap fill (D8), leading silence, and tail padding run on the mic track only (v0.6.0 parity). Legacy 3-track recordings (pre-v0.7.0) remain playable.
- **Transcription is app-level, not view-level.** `TranscriptionCoordinator` (`@Observable`, MainActor, created in `BlackboxApp` and injected into the window environment) owns every transcription; the detail view only observes it. Each finished recording gets its own independent job, keyed by recording-directory path in a `[String: Task]` - jobs are almost entirely *waiting* (a poll loop against Soniox that can run for a minute) and contend with nothing, so serializing them once meant a recording finished at 17:52 did not start transcribing until 18:17, because a call that began a second later ran 23 minutes. Only the local mix is bounded, by `Dependencies.uploadConcurrency` (default 2) around `upload`, where the mix lives. Each job's stage is persisted to a `transcription-job.json` sidecar in the recording directory so an interrupted job resumes by polling the existing `transcriptionId` instead of re-uploading. Auto-trigger fires through `AudioMonitorDependencies.onRecordingSaved`, which every `stop()` returning a URL funnels into - including recorder failures and the quit path. Gated on the `autoTranscribe` setting (default off), a Keychain API key, and a 3-second minimum duration; the setting is re-checked at five points - at resume, on entry to `run()`, on every pass of the job loop, after acquiring an upload slot, and immediately before the call that bills - because every one of those is a wait the user can change their mind during, and `upload` alone is minutes for a long call. There is no recording gate: it was written on an unmeasured premise ("mixing must not compete with a live call for CPU or disk") and its only demonstrated value was deferring at quit, which `suspendNewJobs()` now does precisely. Nothing on this path may join `applicationShouldTerminate`'s 8s budget. See D14 in `docs/specification.md`.
- **Remote artifacts are retired on confirmation, not on dispatch.** `deleteRemote` reports whether Soniox actually deleted every artifact, and `discardRemote` retires the local record naming them only on that answer - guarded by an identity re-read, since the user can start a fresh job while the delete is in flight. A dispatched-but-failed DELETE (a half-typed key, no network) would otherwise erase the last trace of uploaded call audio, and the API-key field resumes pending jobs on a 600 ms typing debounce, which is precisely when that happens. See D14 in `docs/specification.md`.
- **The cold-launch window open is gated on not being a login launch.** Measured: a foreground `open`, a background `open -g` and a login launch are indistinguishable by `NSApplicationLaunchIsDefaultLaunchKey`, by `isActive`, or by the launchd label, and a windowless `LSUIElement` app is never made active, so waiting for an activation waits forever. What separates them is *when*: the window is suppressed only when Launch at Login is enabled and the process started within `loginLaunchWindow` (120s) of the console login record in `utmpx`. Both branches were verified end to end against the real bundle.
- **Path spelling is load-bearing.** Transcription status is keyed by recording-directory path. `FileManager.contentsOfDirectory(at:)` resolves symlinks in its base and returns a different spelling than the recorder produces, so directory scans go through `RecordingStore.directories(in:)`, which enumerates by name and builds child URLs from the caller's base. `finishCounts`, which gates the detail view's transcript reload, is keyed the same way and fails silently if the spellings diverge - the transcript never refreshes in place, though reopening the detail view still loads it. It is a per-path counter rather than the single `lastFinishedPath` it replaced, because with concurrent jobs two finishing inside one SwiftUI observation pass left the variable naming only the second, and the first recording's open detail view never reloaded. `RecordingStore` owns the `audio.m4a` / `audio-processed.m4a` names everywhere. It also holds the processed-preferred rule as `audioURL(in:)`, but only transcription calls it: playback gates on a user toggle, the storage stats sum both files, and the recordings list re-derives the same choice inline because it already has to stat both files for their sizes.
- **An unannotated protocol is `@MainActor` here, and that is what puts async work on the main thread.** Under `.defaultIsolation(MainActor.self)` a protocol declared without `nonisolated` is main-actor isolated, and so are its requirements, so a call through it runs on main no matter how the conforming type is declared. `nonisolated` on the type is not the lever: measured on this target's flags, a `nonisolated` free async function and a plain async method on a `nonisolated final class` both run off main when called concretely. Mark the protocol `nonisolated`, or mark the requirement `@concurrent` - `TranscriptionServicing` does the latter for all five. One caveat, also measured: the rule is about the statically dispatched declaration, so a witness that *also* satisfies an unannotated (therefore `@MainActor`) protocol has its implementation inferred `@MainActor`, and calls through the `nonisolated`/`@concurrent` protocol then run on main anyway, with no diagnostic. `TranscriptionService` conforms to one protocol only, which is what keeps this sound today. See the Key Architectural Constraint in `docs/specification.md` for the measured table; this was documented wrongly twice before anyone ran it.
- **Echo cancellation post-processing**: User-triggered, not automatic - the only call site is `runAEC()` in `MainWindowView.swift`, invoked from the recordings table. DTLN-aec CoreML (256-unit model) processes the mic track using the system audio track (track 0) as the AEC reference and writes `audio-processed.m4a` alongside the original; it is written to a per-run scratch name and moved into place only on success, errors are thrown and shown to the user, and the original is never modified. The decode loop runs on `AECProcessor.workQueue`, never on the Swift cooperative pool: `AVAssetReader.copyNextSampleBuffer` blocks its thread and delivers via libdispatch, so running it on the pool deadlocks once every pool thread is parked inside it.
- **`applicationShouldTerminate` returns `.terminateLater`** to allow async cleanup (stop AVAudioEngine, stop SCStream capture, finalize AVAssetWriter) before process exit. 8-second timeout with `hasReplied` flag to prevent double-reply race.
- **Auto-recovery**: `RecorderFailure` enum categorizes stream errors (system stopped, permission denied). AudioMonitor auto-restarts on recoverable failures.
- **Crash safety**: `movieFragmentInterval` on AVAssetWriter writes fragment headers every 10s, making partial files recoverable.

## Concurrency Model

With `defaultIsolation(MainActor.self)`:
- All types are `@MainActor` by default (BlackboxApp, AudioMonitor, SettingsView)
- AudioMonitor is purely MainActor-isolated (polling-only, no C callbacks)
- AudioRecorder is an `actor` with custom `DispatchSerialQueue` executor (`audioQueue`). All actor-isolated state accessed on `audioQueue` - same runtime behavior as the previous `nonisolated(unsafe)` approach, but with compile-time safety
- RecordingPipeline is `@unchecked Sendable` with `nonisolated(unsafe)` state - safe because all access is serialized on AudioRecorder's `audioQueue`
- SCStream sample handler (via `SCStreamProxy`, a thin NSObject adapter) dispatches to `audioQueue.async` with `assumeIsolated` for direct passthrough to RecordingPipeline (no downmix)
- SCStream stop/error callbacks hop through `audioQueue.async` to `assumeIsolated` for `RecorderFailure` routing
- AVAudioEngine tap callback dispatches to `audioQueue.async` with `assumeIsolated` to serialize with SCStream callbacks
- AVAudioEngine config change observer fires via `Task { await ... }`, actor-isolated `debounceConfigChange` uses `asyncAfter` with `assumeIsolated` for the delayed handler
- D12 supplemental mic-recovery signals feed the same debounced restart: `kAudioHardwarePropertyDefaultInputDevice` CoreAudio listener (dispatch queue = `audioQueue`, block uses `assumeIsolated`) and a `DispatchSourceTimer` watchdog on `audioQueue` that trips when mic buffers stall >2 s; all three sources call `requestMicReinstall(source:)` which logs the source and delegates to `debounceConfigChange`

## Cross-Model Collaboration (Codex)

Claude Code can delegate work to OpenAI Codex via `.claude/bin/codex-bridge.sh`.
Both run on subscriptions - no API keys. The bridge script unsets `OPENAI_API_KEY`
so Codex never accidentally uses your project's API key for billing.

**Commands:**

| Command | Purpose |
|---------|---------|
| `/collab <task>` | Full collaboration: think, build, or debug with Codex |
| `/collab-review` | Quick second opinion from Codex on current changes |

**How it works:** Claude calls `codex exec` via bash. Codex's response streams
directly into Claude's context. Claude reads it, reasons about it, synthesizes.
No tmux, no file polling, no third-party tools. Build tasks run asynchronously
in the background so the user can keep talking to Claude while Codex works.

**Bridge modes:**
- `codex-bridge.sh think "prompt"` - read-only, for debate and review (sync)
- `codex-bridge.sh build "prompt"` - workspace-write, for implementation (async)
- `codex-bridge.sh build "prompt" path/to/spec.md` - build from spec file (async)

**Build specs** go in `.collab/specs/`. **Reports** go in `.collab/reports/`.

**Rules:**
- Never assign overlapping files to both Claude subagents and Codex
- Always run your test suite after Codex builds - never trust the self-report
- Keep Codex prompts concise (500 words max) - it has no session memory
- Synthesize Codex output for the user, don't relay it raw
- Compact context before starting a collab workflow
- Break large builds into 2-3 small focused Codex calls (max 3 files each)
