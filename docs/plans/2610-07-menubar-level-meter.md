# Menu bar level meter

Plan for bringing back the recording icon that reacts to sound. Written
2026-10-07 against `main` at `a0cd5e9`.

## What broke, and when

- `4775b70` (2026-07-03) had the working meter: the recording icon swapped
  between `waveform.low`, `waveform.mid` and `waveform`, bucketed by dBFS
  (above -30 full, above -45 mid), because conversational speech sits near
  -36 dBFS RMS and a linear 0.05 threshold never reached it.
- `6f53333`, squashed into `d280e5f` (2026-08-27), removed the swap on audit
  finding C1 (`docs/plans/2608-27-audit-findings.md`): three glyphs of
  different widths were said to re-lay-out the status item at 4 Hz, the shape
  of an `_postWindowNeedsUpdateConstraints` crash.
- The replacement was one `waveform` glyph with a constant
  `.symbolEffect(.variableColor)` and `opacity = 0.55 + 0.45 * sqrt(level / 0.08)`.
  The effect animates whether or not anyone speaks, and the curve moves only
  from about 0.60 (noise floor) to about 0.75 (speech). It also dims the error
  glyph.

## Why restore the swap rather than invent something new

C1's crash evidence is one unsourced line in the `swift-macos` skill reference;
there is no stack trace, issue or reproduction, and the glyph-width cause was
inferred. The swap shipped from March to August. A `variableValue` glyph
(the other option considered) is plausible but its rendering in a menu-style
`MenuBarExtra` label is unverified, so it would trade a known-working mechanism
for an unknown one. An independent review (Codex, gpt-6-astra) reached the same
recommendation.

## The change

1. `AudioMonitor` publishes `levelSymbol: String` instead of `audioLevel: Float`,
   assigned only when the bucket changes. `@Observable` notifies on every set,
   so this is what keeps the label from being invalidated on every 250 ms level
   tick - the half of C1's fix that was never done.
2. `recordingWaveformIcon(level:)` returns, with the `4775b70` dBFS buckets and
   its two regression tests.
3. The recording branch of `menuBarLabel` shows `monitor.levelSymbol`, or the
   undimmed `waveform.badge.exclamationmark` when there is an error. The 16pt
   frame stays. `.variableColor`, the opacity and `levelOpacity` go.
4. Reduce Motion needs no gate: a glyph swap is an instant state change, not an
   animation, and it carries information.

## Non-goals

- The level is the max of system and mic RMS, so it shows "sound", not "who
  speaks". Splitting it is a separate change.
- The level is callback-driven, so a stalled buffer stream leaves a stale glyph.
  The D12 watchdog already restarts a stalled mic.
- Hysteresis at bucket edges - add only if chatter is seen.

## Verification

1. `make check` (format, build, full suite including hardware).
2. On the installed app, during a manual recording: silence shows `low`,
   normal speech shows `mid`, loud speech or system audio shows `waveform`;
   check with the menu open and closed, and in light and dark menu bars.
