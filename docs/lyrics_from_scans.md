# Lyrics from scans — spike findings (2026-10-17)

**Question.** A scanned song loses its lyrics. Can we read them and put each
syllable on the right note?

**Answer: yes, without help from homr's recogniser.** On six keyed pages (342
lyric-bearing notes), **330 got exactly the right syllable (96%)**. Four more
got a "?" placeholder exactly where Vision dropped a word, so 334 (98%) are
either right or flagged for the user. Four pages score 98–100%. All are clean images, either PDFs rendered to PNG or screenshots;
**phone photos, the real input, are the next test.**

## Benchmark

`bash lyrics_eval/score.sh` (gitignored folder; numbers only). Pages are rendered
at 200 dpi from public-domain sources, plus one screenshot:

| Page | Source | Systems | Exact |
|---|---|---|---|
| Along the Road to Gundagai | screenshot of a modern engraving (1922 song) | 8 | 129/131 (98%) |
| Sourwood Mountain | Campbell & Sharp, *English Folk Songs from the Southern Appalachians* (1917), p. 312 | 3 | 40/40 (100%) |
| A Frog He Went A-courting | same, p. 317 | 5 | 67/72 (93%), plus 1 "?" |
| The Single Girl | same, p. 256 | 3 | 41/44 (93%), plus 3 "?" in the right places |
| Barbara Allen (A) | same, p. 90 | 2 | 31/33 (94%) |
| The Wagoner's Lad (A) | same | 2 | 22/22 (100%) |

The 1917 book is [IMSLP #248925](https://imslp.org/wiki/English_Folk_Songs_from_the_Southern_Appalachians_(Campbell,_Olive_Dame)):
one melody staff with verse 1 underneath, and the remaining verses printed as
plain stanzas below. It's old-time repertoire, and the scan is real (faint staff
lines, yellowed paper). Two copyrighted lead sheets (three stacked verses; an
all-caps jazz font) are in the folder unkeyed, for structure checks only.

**What the 13 misses are:**
- **OCR drops one-letter words** ("I", "a"), and the aligner can't always tell
  which gap they belong in.
- **A stray glyph** read from a notehead knocks the syllables after it out of place.
- **homr missed a slur**, so a melisma's syllable lands one note early.

None of the misses is an alignment error on correctly read input.

## "?" for words Vision dropped

Vision silently drops lone one-letter words ("I", "a") in widely spaced lyrics,
in two different ways: either it never boxes the word at all, or it boxes it and
then leaves it out of the text. Neither re-reading a crop of the gap nor reading
at 2× brings them back. So the spike finds them from the image instead, and puts
a **"?"** syllable there for the user to fill in.

1. **Find word-shaped ink:** in each lyric line's x-height band, found from the
   line's own row profile. Columns join one word if they have ink anywhere from
   ascender height down to the baseline, which keeps a T's crossbar or an
   apostrophe with its word. Hyphens (a sliver of the band) and extender lines
   (on or below the baseline) don't count.
2. **Match ink to words:** inside each Vision box, the box's words (with
   run-together words split) are matched to the ink patches in order, by
   expected width. A patch left over is a dropped word; so is a patch outside
   every box.

On the benchmark it placed 4 placeholders, all on notes that needed a word, and
none where they didn't. It stays quiet on tightly kerned engravings, because
their words don't separate into patches.

**Filling the "?" with an on-device language model:** possible, but not for the
easy cases. The app never goes online, which rules out a cloud model, and also
keeps copyrighted lyrics on the device. iOS 26's Foundation Models framework
runs offline on Apple Intelligence devices. It could suggest a missing word from
context (for example, the word missing from Gundagai's first line), shown as a
suggestion the user confirms rather than as the printed lyric. A better first
use for it might be the songbooks that print verses 2 onward as plain stanzas:
those need hyphenating into syllables before they can be laid under the notes.
A standard offline hyphenation dictionary may cover that without a model.

## What homr does and doesn't give

- **No lyrics.** homr's decoder vocabulary has no text tokens, and neither port
  emits `<lyric>`, `<words>` or `<harmony>`.
- **Systems, yes.** One `<print new-system>` per system. Every page's count
  matched. This is the anchor the whole approach rests on (see "global" below).
- **Slurs: only homr_flutter.** Upstream Python homr writes empty `<notations/>`;
  homr_flutter (what the app runs) keeps `slurStart`/`slurStop`. The spike
  restores them from the Python token log. Ties come out as slurs in both, so a
  slur stop on the same pitch is read as a tie.
- **No note x-positions.** They weren't needed.

## How the spike works

`docs/omr_evaluation/scripts/ocr.swift` and `lyrics_align_spike.py`.

1. **OCR: Apple Vision** (accurate, language correction off), on-device. The
   page is read **twice, whole and in overlapping horizontal strips**, and the
   reads are merged. Each pass skipped a whole lyric line that the other got.
2. **Lines:** clustered on the text baseline, not the box centre. A read that
   swallows the notes above it has a tall box but still sits on its line. A line
   is lyrics only if **a staff is the first thing above it**, found from row
   darkness as a stack of at least four thin rules. That one test removes
   titles, credits, chord rows and the printed stanzas after the music. Text with
   two or more rules running through it is noteheads misread, and is dropped.
3. **Verses:** lines stacked close under one system are verses 1, 2, 3, and are
   written as `<lyric number="n">`. They must span the music like verse 1; the
   indented, narrower stanzas below the music do not.
4. **Syllables:**
   - Split on spaces and hyphens.
   - Words printed with no space between them are split against
     `/usr/share/dict/words`, never inside a piece with hyphens on both sides.
   - Repairs to Vision's habits: a bullet read for a hyphen, "I." or "1." as a
     verse number, "/" for an italic I, Cyrillic look-alikes, and "_" or "—"
     read as extender lines.
5. **Alignment:** a monotone DP per system. Every syllable gets its own note, and
   leftover notes are skipped.
   - **Skipping a note is cheap** inside a slur, under an extender (a thin stroke
     in the image after the syllable), where the text has a wide gap (a missing
     word), or where a non-word has two vowel groups (a lost hyphen).
   - **Skipping is dearer for long notes.**
   - **Two pieces can share a note.** When Vision splits one syllable in two,
     the pieces nearly touch, so the cost of sharing grows with the gap between
     them.

**Why not x-positions?** On the Gundagai page the lyrics are not set under their
notes: whole lines are shifted left by up to half a measure. Order, counts,
slurs and extenders carried it.

## Measured and rejected

| Idea | Result |
|---|---|
| **Global alignment** (`LYRICS_ALIGN=global`): read all the lyrics as one stream and lay it against every note, ignoring line breaks | **56%** against 96% per system. One missing word shifts everything after it for the rest of the song; line breaks act as checkpoints that limit the damage. Only the pages with one syllable per note on every system were unaffected. |
| **OCR upscaling** to 2400 px wide (`OCR_MIN_WIDTH=2400`) | **80%** against 90% at the time. It recovers some one-letter words but breaks more elsewhere. Kept off. |
| **Count-aware gaps** (a wide gap expects N missing syllables, and only N skips there are cheap) | **92%** against 96%. Reverted. |

## What it would take as a feature

- **Plug-in point:** `lib/screens/scan_screen.dart`, between `scan()` and
  `savePiece`. The MusicXML and page crops are both in hand there. Everything
  downstream (parser, Verovio, verse picker, editor) already handles `<lyric>`.
- **OCR is per-platform.** Vision on iOS/macOS goes through a small platform
  channel (two passes, as above). Android would use ML Kit, and web either
  tesseract.js or nothing, behind an `_io`/`_web` split. With no OCR the scan
  comes out exactly as it does today.
- **The aligner is plain Dart:** a port of about 400 lines of Python, pure and
  unit-testable. Staff detection needs only page pixels, and homr_flutter already
  exposes slurs, so no package change is needed.
- **Chord symbols come nearly free** from the same OCR pass (`<harmony>`).
- **Surface what's unplaced.** The aligner knows when a system has more notes
  than syllables. The measure editor could flag those for a quick fix.

## Future: song title detection (not started)

The user wants titles detected too. Notes from this spike:

- **homr doesn't do it.** homr_flutter's README says title detection is not
  ported. Upstream Python homr logs a `Found title:` line, which was empty for
  the Gundagai screenshot.
- **Vision already reads titles**, at confidence 1.0, in the same pass as the
  lyrics. The spike throws them away. "No staff above" plus "tallest text on the
  page" picks them out: the old title filter was text taller than 1.6× the
  median height, which worked until a tall OCR box (text plus notes) fooled it.
  Use baseline-clustered line height, not box height.
- **Things that look like a title but aren't:** the songbook number above it
  ("No. 114"); a subtitle variant letter ("A") under it; right-aligned credits
  ("Sung by …", composer and lyricist names), often on the same baseline as a
  left-aligned mode or tempo note; tempo marks ("♩ = 92"). Credits sit
  between the title and the first staff, and are smaller.
- **Multi-page scans:** only the first page has the title.
- **Useful beyond naming:** a detected title could prefill the save dialog in
  `scan_screen.dart` and set `<work-title>`.

## Copyright: how evaluation works

Copyrighted lyrics never leave the machine. The spike prints counts and scores
unless `LYRICS_SHOW=1` is set, for a person reading locally. Answer keys for
copyrighted pages are written by the user. Everything lives in the gitignored
`lyrics_eval/` folder. Public-domain pages (Gundagai, 1922; the 1917 book) can
be discussed and keyed freely. The production feature is on-device by design.

## Next

1. **Phone photos** of printed copies of the 1917 pages: perspective, uneven
   light, and lower effective resolution.
2. Keys for the two copyrighted pages (user-written) to check stacked verses and
   the all-caps font.
3. The remaining misses: a stray glyph read from a notehead, and melismas
   where homr missed the slur.

## Reproducing

```bash
swift docs/omr_evaluation/scripts/ocr.swift page.png > ocr.json
homr page.png > homr.log                      # writes page.musicxml
python3 -I docs/omr_evaluation/scripts/lyrics_align_spike.py \
    --template page.musicxml homr.log answer.gt.txt   # fill in, one row per note
~/.local/share/uv/tools/homr/bin/python -I docs/omr_evaluation/scripts/lyrics_align_spike.py \
    ocr.json page.musicxml answer.gt.txt out.musicxml homr.log page.png
bash lyrics_eval/score.sh [--ocr]             # every page, numbers only
```
