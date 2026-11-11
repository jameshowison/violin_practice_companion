# Exploration plan: fixing the errors homr is known to make

Status: idea, not started (2026-11-10).

## Why

Rescanning Allegretto (2026-11-10) gave notes identical to the hand-corrected
version, plus the same marking errors that were hand-fixed on 3 Nov:

- **bar 3**: a triplet marked on four notes that aren't a triplet (removed by hand before; back again);
- **bar 13**: a fermata that isn't printed;
- **bars 5–8, 16**: accents and staccatos missed or duplicated.

The 3 Nov corrections (`../violin_dev_library`, commits `e2df114`,
`aa7f90e`, `843c5a9`) were made by comparing each scan with a reference
score and the printed page. That can't happen for a piece nobody has
transcribed. But homr's errors repeat: the same input gives the same mistake,
and some kinds of mistake recur across pieces. So some fixes may not need a
reference score:

1. **Rules**: a check that finds a mistake in any piece, from the score alone.
2. **Stored fixes**: corrections remembered for a piece we've corrected before,
   applied again when it is rescanned.

## The corpus we already have

- **Raw vs corrected pairs.** Each `scanned_pieces/<id>.musicxml` in the dev
  library has its raw scanner output as its first commit (mostly `35bdce0`)
  and the corrected version at HEAD. That's 19 Suzuki Book 1 pieces plus a
  few others.
- **The scanner's inputs.** `scan_sources/<id>/page_<n>_crop.*` lets us rerun
  the *current* homr_flutter and get a fresh raw output, since the first
  commits came from older scanner versions.
- **The reference scores** behind the corrections (homr_flutter's
  `docs/omr_evaluation`, Suzuki Book 1).
- Notes from earlier error hunts: `docs/postmortem-undrawn-accidentals.md`,
  and the naturals the model was never trained on (`_NaturalAccidentalHint`).

## Step 1: catalogue the errors (cheap, do first)

Write a script (Python, in `tools/`, like `pull_dev_library.sh`'s helper) that
lines up raw and corrected versions bar by bar (as the comparison of
2026-11-10 did) and records each difference as a typed edit:
`pitch`, `accidental`, `duration`, `tuplet added/removed`,
`articulation added/removed (accent, staccato, fermata, trill, tremolo, comma)`,
`slur/tie`, `repeat/ending`, `clef/key/time`.

Output: counts per edit type across the corpus, and the bars where each
occurs. That shows which errors are common enough to be worth a rule and
which are one-offs. Rerun it against fresh homr outputs to see which errors
the current scanner still makes.

## Step 2: rules (fixes that need no reference)

Candidates, each to be measured on the catalogue before it is adopted:

| Rule | Evidence for it | Risk |
|---|---|---|
| **Tuplet that breaks the bar.** If a bar adds up to the time signature *without* a tuplet marking and overflows or underflows *with* it, drop the marking. | Allegretto bar 3 | Real triplets in a bar that's already wrong for other reasons |
| **Mark the scanner rarely reads correctly.** Fermata, trill and tremolo mid-phrase in Book 1 repertoire are usually pencil marks (843c5a9 dropped several). Flag them rather than delete them; a fermata on the final note is probably real. | 843c5a9 | Real fermatas mid-piece (Allegro, Andantino have them) |
| **Missing naturals.** The model never sees ♮. A note that follows the key signature where the same note a beat earlier was marked natural, or where the melody runs chromatically, gets flagged. | known training gap | Flags only, no fix |
| **Repeated passages.** Where two passages have the same notes (Allegretto's bars 13–16 repeat bars 5–8), make their articulations agree, taking the version with more marks read. | Allegretto 5–8 vs 13–16 | Composers do vary repeats |

Rules would live next to the existing repair passes (`_repair` in
`piece_repository.dart`, `MusicXmlNormalizer`), as **flags** where we're
unsure and **fixes** only where the catalogue shows they're nearly always
right. A flag could be shown on the bar in the measure editor.

Measure each rule by how many catalogued errors it fixes and how many correct
bars it breaks, both across the whole corpus. Adopt one only if it breaks
nothing, or close to nothing.

## Step 3: stored fixes for pieces we've corrected before

When a new scan looks like a piece already in the library (same title, which
we now read automatically, and notes that mostly match), we already have a
corrected version of it. Options, smallest first:

1. **Offer the corrected version**: "This looks like *Allegretto*, which you've
   corrected before. Use that instead?" Zero modelling; covers rescans like
   2026-11-10's.
2. **Replay the corrections**: store the diff (raw → corrected) per piece,
   keyed by the note sequence, and apply each edit whose bar still matches
   the new scan's raw output. That helps when the new scan differs a little
   (a different photo, a different crop) but makes the same mistakes.

(1) is probably all that's needed; (2) only matters if pieces are rescanned
from different editions or photos often enough to diverge.

## Open questions

- How much does the error pattern depend on the photo or the crop rather than
  the score? Rescanning the same page with a couple of crops would say how
  stable homr's mistakes are, which decides whether stored fixes (step 3.2)
  can work.
- Should rules run silently at import, or only flag? A silent wrong fix is
  worse than a visible flag; start with flags.
- Fixes found here that are really recogniser bugs (e.g. the triplet) might
  belong upstream in homr_flutter's assembler rather than the app.
