# DTW auto-alignment: recordings with an unmatched intro/outro distort the boundary measures

**See also:** [audio-sync-dtw-anchor-compression.md](audio-sync-dtw-anchor-compression.md) —
a different DTW quirk on the same code path (chroma-ambiguous *interior* measures, not
the recording's start/end), worth reading together since both affect anchor quality
and both are now handled by "flag, don't silently fix."

**Component:** `DtwAligner.align` / `AudioScoreAutoAligner.align`
**Files:** `lib/services/dtw_align.dart`, `lib/services/audio_score_auto_aligner.dart`
**Severity:** wrong local timing at the start and/or end of a piece, not a crash
**Affects:** any recording with lead-in or trail-out content the score has no
counterpart for — confirmed case: Lightly Row's `melody.mp3`/`mix.mp3` (a several-second
performance-tempo intro before the tune starts)

## Summary

`DtwAligner.align` used to force its path to run corner-to-corner: reference frame 0
had to match audio frame 0, and the last reference frame had to match the last audio
frame. When a real recording has audio before/after the score's own content — a
spoken or instrumental intro, a count-in, a trailing fade — that forced correspondence
squeezes the entire unmatched region into a false match against the score's first (or
last) notes, distorting those measures' anchors. This is exactly what a session with
the newly-added Lightly Row play-along recording surfaced as "weird first measure
alignment."

## Reproduction

Lightly Row's recording has a several-second performance-tempo intro before the
violin/piano performance begins; the score has no equivalent lead-in. With the old
corner-to-corner DTW, `anchors[0].audioSec` landed near `0.0` regardless — the intro
got compressed into a match against the score's first note instead of being
recognized as unmatched content.

## Why it matters

Play Along's cursor is driven by piecewise-linear interpolation between anchors; a
first anchor forced to `audioSec ≈ 0` when the real first note doesn't sound until
several seconds in means the cursor races through the entire first measure (or more)
while the recording is still playing its intro, then snaps back in sync once later
anchors take over.

## Rejected alternative: a manual "intro seconds" flag

Considered and rejected in favor of the fix below: a per-track metadata field giving
the intro's length in seconds, subtracted before/after alignment. Simpler to
implement, but requires per-recording manual tuning (measuring or guessing the intro
length by ear for every piece/track that has one) and doesn't generalize to future
recordings without repeating that step.

## Fix: open-begin / open-end (subsequence) DTW

`DtwAligner.align` gained `openBegin`/`openEnd` optional parameters (default `false`,
today's exact corner-to-corner behavior — `test/dtw_align_test.dart`'s existing
assertions needed no changes). When either is `true`, `_alignWithBand` relaxes the
corresponding DP boundary condition instead of forcing it:

- **Open-begin:** row 0 of the cost matrix (`"0 reference frames consumed"`) is
  seeded with a small per-frame skip cost (`_skipPenaltyPerFrame * j`, currently
  `1e-3`/frame) instead of `0` only at `j = 0`, so the first reference frame can pair
  with any target frame `j`, paying only that small skip cost for however much
  leading audio came before it — cheap next to a real mismatch (cosine distance up to
  `2`), but enough to prevent the optimizer from shaving off real, matched content for
  a change in cost too small to be genuine (see "A subtlety" below).
- **Open-end:** instead of forcing the traceback to start at `(n, m)`, it starts at
  whichever `j` minimizes `cost[n][j] + _skipPenaltyPerFrame * (m - j)` — the same
  small-penalty logic applied to however many trailing frames are left unmatched.
- Banding is bypassed (full unbounded search) whenever either flag is set, since the
  Sakoe-Chiba band's diagonal-centering assumption presumes synchronized start/end.
  Piece lengths here (a few thousand frames each way) make this computationally free.

`AudioScoreAutoAligner.align`'s one call site now always passes `openBegin: true,
openEnd: true` — safe for a recording with no intro/outro too, since the closed
corner-to-corner path remains an available candidate in the wider search space.

### A subtlety: why the skip cost can't be zero

A literal zero-cost skip (the naive textbook formulation) was tried first and broke
existing, previously-correct alignments: a long sustained tone (or, more realistically,
a measure of six repeated identical pitches, as Salt Creek's measure 1 turned out to
be) makes nearly every frame inside it look like an equally good match, so a
zero-cost skip can shave off real content for a "cheaper" alignment that differs from
the true one by only floating-point noise (observed: an unrelated regression test's
`averageCost` improved from `0.01681856` to `0.01681842` — a `1.3e-7` difference —
by skipping 2.18s of genuinely correct content). The small per-frame penalty fixes
this: skipping is only chosen when it's a real improvement, not a coin-flip tie. The
penalty's own contribution to the returned `averageCost` is subtracted back out before
reporting (exactly calculable, since it enters the cost matrix exactly once, as the
open-begin base case) so the metric still reflects genuine match quality.

## Resolution (2026-09-14)

Implemented as described above. Verification:

- `test/dtw_align_test.dart` — new `group('open boundaries', ...)` covering
  open-begin-only, open-end-only, both together, closed-mode-still-forces-corners
  (demonstrating the distortion this fixes), and open-vs-closed-cost-is-never-worse
  on content with no intro/outro. All pass; none of the pre-existing tests changed.
- `test/audio_score_auto_aligner_test.dart` — new regression test: a synthetic
  recording with a 2.5s unrelated-pitch "intro" prepended now anchors measure 1 near
  `audioSec ≈ 2.5` (previously ≈ `0`).
- `test/salt_creek_auto_align_test.dart` — re-run against the real
  `assets/audio/salt_creek/melody.wav`. Measure 1's anchor moved from a forced `~0s`
  to a discovered `3.460s` — confirmed genuine, not a new artifact, by the test's
  independent (chroma-free) onset detector: anchor 1 lands within 0.1s of a real
  detected onset. Measure 1 is itself six repeated notes of the same pitch, so exactly
  which of several very similar nearby onsets gets picked is inherently ambiguous —
  this run's `hasCompressedAnchors` came back `true` (measure 2's anchor lands
  suspiciously close to measure 1's), which is the existing, correct "ask a human to
  check" signal for that ambiguity (see the anchor-compression doc), not a regression
  introduced here. The stale `anchors.first.audioSec < 2.0` assertion (written when
  the aligner always forced measure 1 to `~0`) was widened to `< 5.0` with a comment
  explaining the new expected value.
- Full `flutter test` run: no other regressions (one pre-existing, unrelated failure —
  `playback_service_base_test.dart`'s `highlightDownbeatOnly defaults to off` — was
  confirmed to fail identically on unmodified `main` via `git stash`).

*Measured against the real `assets/audio/salt_creek/melody.wav`, 2026-09-14.*
