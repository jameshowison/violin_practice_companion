# DTW auto-alignment: anchor spacing can locally collapse at chroma-ambiguous measures

**Component:** `AudioScoreAutoAligner.align` / `DtwAligner.align`
**Files:** `lib/services/audio_score_auto_aligner.dart`, `lib/services/dtw_align.dart`
**Severity:** wrong local timing, not a crash — the cursor briefly desyncs from the
audio, then re-syncs at the next anchor
**Affects:** any piece where two (or more) consecutive measures have similar enough
chroma content that the DTW cost matrix has little to discriminate on — likely
common in fiddle tunes, which lean on short repeated melodic cells

## Summary

`DtwAligner.align` finds a monotonic path through a reference (score) × target
(audio) cost matrix; `AudioScoreAutoAligner.align` turns that path into one
`ScoreAudioAnchor` per performed measure. The path is monotonic but not
speed-limited — nothing stops it from advancing many *reference* frames while
barely advancing through the *target* audio, if the audio frames along the way all
look like an equally good (equally bad) match. When that happens locally, two (or
more) consecutive anchors land close together in `audioSec` while still far apart
in `scoreMs`, and `AudioSyncPlaybackService`'s piecewise-linear interpolation
(`_scoreSecForAudioSec`) then has to sweep the full `scoreMs` gap in that tiny
`audioSec` window — the cursor visibly "zooms" through a measure's worth of notes
in a fraction of a second before landing back in sync at the next well-placed
anchor.

## Reproduction

Salt Creek, real recording, this session. The user had just added a repeat-start
barline the score was missing (measure 10, marking the start of the second strain
— see "Piece structure" below) and clicked Realign. The freshly-computed alignment,
read directly out of the simulator's preferences plist
(`flutter.audioSyncAnchors.untitled_2026_09_08t11_19_17_445148_1788884398656`),
came back as `generationBpm: 191` with 34 anchors (one per performance-order
measure). Computing each anchor's delta from the previous one:

```
idx  scoreMs delta   audioSec delta
 1        314.1           2.624
 2       1256.5           0.952
 3       1256.5           1.207
 4       1256.5           1.161
 5       1256.5           1.324
 6       1256.5           1.068
 7       1256.5           1.231
 8       1256.5           1.184
 9       1256.5           1.207
10       1256.5           1.231
11       1256.5           1.184
12       1256.5           1.161
13       1256.5           1.347
14       1256.5           1.068
15       1256.5           1.231
16       1256.5           1.161
17       1256.5           1.207
18       1256.5           0.557   <<< compressed
19       1256.5           0.697   <<< compressed
20       1256.5           1.161
21       1256.5           1.207
22       1256.5           1.184
23       1256.5           1.184
24       1256.5           1.231
25       1256.5           1.184
26       1256.5           1.138
27       1256.5           0.580   <<< compressed
28       1256.5           0.697   <<< compressed
29       1256.5           1.184
30       1256.5           1.207
31       1256.5           1.207
32       1256.5           1.184
33       1256.5           1.207
34       1256.5           1.184
```

32 of 34 boundaries pace at a uniform ~1.19s/measure (`scoreMs` delta is exactly
`1256.5` throughout — one 4/4 measure at 191 BPM — so the score side is fine; only
the audio side misbehaves). At anchors 18-19 and 27-28, roughly two measures'
worth of score time (2,513ms) map to only ~1.25s of real audio — almost exactly
half the expected pace. That's the "zoom through" the user reported.

**Piece structure** (for context — this is what produced this particular anchor
set): Salt Creek's stored MusicXML has 18 measures — measure 1 is a pickup, `|:`
(repeat forward) at measure 2, `:|` (repeat backward) at measure 9, `|:` at measure
10, `:|` at measure 18. The forward repeat at measure 10 was the one the user had
just added; `ParsedPiece.performanceOrder` expands this correctly (verified by
hand-tracing it) into pickup, A (2-9), A again, B (10-18), B again — 34 performance
measures total, matching the anchor count above.

## Why it matters

This is a Play Along-specific correctness gap. It's independent of — and was
found only after fixing — the two structural bugs from earlier in this session
(the repeat-boundary cursor jump from a duplicated, non-forward-only highlight
pointer, and Play Along ignoring the measure selection). Both of those are fixed
now (`AudioSyncPlaybackService` is a real `PlaybackServiceBase` subclass). This
compression issue is a different thing: even with perfect plumbing, the anchors
themselves are locally wrong at these two spots, so the cursor will visibly desync
from the audio there no matter how good the playback-service architecture is.

## Suggested fix options

Discussed with the user; left for a future session to pick from and implement.

1. **Post-hoc outlier smoothing (recommended).** After DTW produces the anchor
   list, compare each segment's `audioSec` delta against a rolling median of
   nearby segments; where a segment (or pair) deviates sharply, discard those
   anchors and re-interpolate from their non-outlier neighbors instead of trusting
   the raw DTW path there. Fully automatic, no UI, no change to the DTW core —
   would live in `audio_score_auto_aligner.dart`, likely as a small new
   post-processing function. `AudioSyncPlaybackService.sortAnchors` (extracted as
   a public static method this session specifically so it could be unit-tested in
   isolation) is a reasonable precedent for how to structure and test it — a new
   fixture reproducing this exact compression pattern (e.g. two adjacent
   near-identical measures) would make a good regression test in
   `test/audio_score_auto_aligner_test.dart`.
2. **Improve the DTW cost function.** Add a discriminating feature beyond chroma
   (e.g. onset/rhythm strength) so the path doesn't collapse through
   similar-sounding measures in the first place. More general and more robust,
   but more work, and doesn't come with an obvious quick regression test the way
   option 1 does.
3. **Leave it as a known limitation.** Accept the two rough spots on this piece
   for now; revisit if this shows up across more pieces once there's a wider
   sample of real recordings to test against.

## Resolution (2026-09-14)

Option 1 was implemented, then reverted the same day. The forward-repeat at
measure 10 mentioned above under "Piece structure" turned out to be wrong: the
user had meant to encode a first/second ending (not currently supported) and
instead left the score with extra, duplicate measures after an over-deletion
while editing. Once the score was corrected in the app, the underlying
structural mismatch — not a DTW quirk — was the actual cause of the anchor
compression seen here.

So `AudioScoreAutoAligner` no longer silently discards squeezed anchors.
`hasCompressedRun` (renamed from `smoothAnchors`, same detection logic, no
removal) only flags the pattern; `AutoAlignmentResult.hasCompressedAnchors`
carries the flag through `AudioSyncAnchorsStore` to `AudioSyncPlaybackService
.alignmentLooksUncertain`, which `PlayAlongControls` surfaces as a warning
icon with `alignmentReviewMessage` — pointing the user at the score (first/
second endings, an extra or missing measure) instead of guessing which
anchors to drop.

---

*Measured against the real `assets/audio/salt_creek/melody.wav` via the live
cached alignment on `dev-iphone`, 2026-09-14.*
