# Post-mortem: chromatic notes played but never drawn (2026-10-17)

For an agent hunting related bugs. The checklist at the end is the useful
part; the rest explains why each item is on it.

## Symptom

On the scanned "Gundagai (lyrics)", the fingering view showed **1** on the A's
at "And the Mur-rim-bid-gee's" (app bars 28–29) and **0** on other A's, but the
staff showed plain A's with no sharp sign. The printed score has `♯A`. The
fingering was right (A♯ = low 1 on the A string), and so was playback. Only the
engraving was wrong.

That is the useful kind of disagreement. The fingering view, playback, jianpu
and tab are all computed from the **sounding** pitch (`NoteEvent.midiNumber`).
The staff comes from Verovio's reading of the **notation**. When they disagree,
one of the two halves of the MusicXML is missing.

## Root cause

MusicXML records pitch and notation separately:

| Sounding (what plays) | Drawn (what is engraved) |
|---|---|
| `<pitch><alter>` | `<accidental>` |
| `<tie>` | `<notations><tied>` |
| `<sound dacapo="yes">`, `<sound tempo>` | `<words>D.C.</words>`, `<metronome>` |

A writer is expected to fill in both. Readers differ when one half is missing.
MuseScore works the signs out from the pitch. **Verovio takes the file
literally**: an `<alter>` with no `<accidental>` becomes `accid.ges` (gestural,
not drawn).

homr_flutter's `MusicXmlAssembler` (`lib/src/pipeline/musicxml_assembler.dart`)
turned the model's `lift` token into `<alter>` and never wrote `<accidental>`.
The model's `lift` is the *sounding* alteration: every F in G major comes out
`#` even though none is printed. So the information about which notes had a
visible sign never existed, and the writer had to work it out. It didn't. It
also put `<alter>` after `<octave>`; the schema requires step, alter, octave.
Verovio tolerated that, but a stricter reader may not.

## Why it went unnoticed

- **Verovio fails silently.** There was no warning and no wrong pitch, just a
  missing glyph.
- **The tests checked the sounding half only.** `musicxml_normalizer_test.dart`
  asserts MIDI numbers. Nothing asserted what gets engraved.
- **A comment vouched for the scanner's output.** `MusicXmlNormalizer`'s
  docstring listed "the OMR output" alongside MuseScore as conforming, because it
  states sounding pitch. That's true of `<alter>`, and it made the other half
  easy to assume.
- **The bundled pieces had it too.** `assets/fixtures/homr_14_minuet_no_2.xml`
  (D♯), `homr_15_minuet_no_3.xml` (C♯) and `homr_17_gavotte.xml` (C♯) are older
  output from the same scanner. They have been engraved without those signs all
  along.

## Fix

1. **At the source**, homr_flutter 0.1.1 (commit `34755ee`, not yet tagged).
   `_addAccidentals` draws a sign wherever a note's alteration differs from the
   key signature and the earlier notes in the bar. The bar so far is tracked per
   staff, step and octave. A note tied over from the previous bar is never
   re-marked. `<alter>` is now written in schema order. Tests:
   `test/musicxml_assembler_accidentals_test.dart`.
2. **For files already on devices**, `MusicXmlNormalizer.drawAccidentals`.
   It runs in `PieceRepository._repair` after `toSoundingPitch`, using the same
   rule. A file that already has every sign it needs comes back unchanged,
   character for character. File-backed pieces are rewritten on their next load.
   Bundled assets are repaired in memory only; the files themselves still lack
   the signs.

Affected files found by surveying `assets/` and `../violin_dev_library`: the
three `homr_*` fixtures, the `homr_15` editable copy, both Gundagai scans, and
`untitled_2026_09_08t11_19_17_445148_1788884398656` (9 signs).

## How to find more of these

**Compare the two halves.** For accidentals, count notes Verovio reads as
sounding-only:

```js
// node, from the repo root. See CLAUDE.md "Measuring Verovio headlessly".
const vrv = require(process.cwd() + '/web/verovio/verovio-toolkit-wasm.js');
// once vrv.module.calledRun:
const tk = new vrv.toolkit(); tk.resetOptions(); tk.loadData(xml);
const mei = tk.getMEI();
// <accid accid.ges="s" …> with no plain accid="…" is a sign that sounds but isn't drawn
```

Gestural-only accidentals on F's in G major are expected. On any other step
they're a bug.

**Survey every piece** by running a repair pass over `assets/**` and
`../violin_dev_library/**` in a throwaway `flutter test`. Print the files whose
output differs from the input. That gave the list above in a second.

## Leads: possibly related, not yet fixed

1. **Ties are scanned as slurs (confirmed, likely the biggest).** homr's
   vocabulary has no tie articulation, only `slurStart`/`slurStop` (plus a
   `tieSlur` rhythm token the assembler ignores). The Gundagai scan has 0
   `<tie>`/`<tied>` and 17 `<slur>`. The whole-note G in bar 4 is "slurred" to
   the G in bar 5. Verovio draws an arc that looks right, but `MidiGenerator`
   re-attacks the note, and anything that counts notes (practice tracking,
   audio-sync anchors, lyric alignment) sees two notes where the player plays
   one. A slur between two adjacent notes of the same pitch is a tie, so it
   should become `<tie>`+`<tied>`. Decide whether that belongs in the assembler
   (at the source) or in `_repair` (fixes existing scans). It probably needs
   both, as with accidentals. Check whether upstream Python homr converts these
   in its own MusicXML writer.
2. **Bundled `homr_*` fixtures.** They are repaired in memory, but any test or
   tool that reads them raw still sees no signs. Consider rewriting the asset
   files through `_repair` once, and the same for any other generated fixture.
3. **The measure editor's accidental buttons**
   (`lib/screens/edit_measure_screen.dart`, around lines 197–215 and 564).
   The highlighted button comes from `displayAccidental`, the *drawn* half. For
   an unrepaired chromatic note it showed "none (follow key)" on an A♯, and
   pressing "none" would change the pitch to A. The repair now supplies the
   sign, but check:
   - What happens when a note with a sign is moved to another step: does the
     stale sign follow it?
   - Whether `_setAccidental` takes an earlier sign in the same bar into
     account (it uses `KeySignature.defaultAlter` only).
4. **Other writers in this repo.** `measure_xml_editor.dart` writes
   `displayAccidental` verbatim, which is correct as long as callers keep it in
   step with the pitch. `tab_score_generator.dart` lists `accidental` in its
   element order; check that it actually writes signs for chromatic notes.
   `abc_exporter.dart` handles carry itself. `verovio_engraver.dart` around line
   881 inspects accidentals in the generated SVG; check whether it assumed
   scans have none.
5. **The other sounding/drawn pairs.** For each, check which half the scanner
   writes, which half the app reads, and which half Verovio reads:
   - tempo (`<sound tempo>` vs `<metronome>`)
   - dynamics (`<sound dynamics>` vs `<dynamics>`)
   - tuplets (`<time-modification>` vs `<tuplet>`)
   - repeat endings (`<ending>` with and without `<sound>`)
   - hidden notes (`print-object="no"`)

   The parser already reads both tie forms and both D.C./Fine forms. That
   pattern of reading both and writing both is the one to copy.
6. **Interaction with the normalizer's convention test.** `toSoundingPitch`
   decides a file is sounding-led if any note has an `<alter>` with no
   `<accidental>`. After `drawAccidentals`, a C-major scan whose every alter now
   carries its sign *looks* drawing-led. It still reads correctly, because a
   drawn sign is taken at face value; `drawAccidentals: … idempotent, and the
   result still sounds the same` pins this. Any change to either pass must keep
   that test green.
7. **What the new pass doesn't do.** It adds no courtesy accidentals (for
   example a reminder ♮ in the bar after an A♯). It treats carry as
   octave-specific, and it doesn't re-mark a note tied over a barline. These are
   conventions, not bugs, but if an engraving looks "missing a natural", check
   these first.
