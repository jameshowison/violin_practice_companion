# A family of practice companions: the approach, and how it specializes

Status: proposal, 2026-11-19. Nothing here is built. The companion document,
[`libraries.md`](libraries.md), says which shared code becomes libraries and in
what order.

Stringlings is a practice companion for violin, with mandolin behind a setting.
This document has two parts:

- **Part 1** describes what it does without mentioning any instrument.
- **Part 2** says what changes for each group of instruments.

The claim is that most of the app, roughly the scanning, the notation, the
practice loop, the alignment and the library, is already instrument-free. What
is not instrument-free goes through one narrow idea that can be replaced by an
`InstrumentProfile`.

---

## Part 1. The approach, without an instrument

### Who it is for

A beginner, and the adult helping them between lessons, who often cannot read
staff notation. The README's problem statement holds for any instrument:

- the lesson happens once a week
- practice happens every day
- the helper cannot tell which note is next, where it went wrong, or what the
  teacher said about bar 9

The same commitments carry to every app in the family:

- offline; no account, no server, no subscription
- GPL, buildable by anyone
- **no copyrighted music shipped.** The family scans the book it already owns;
  the app bundles only public-domain tunes (`assets/library/catalog.json`,
  enforced by `test/release_content_test.dart`)
- no editorial choices copied from an edition. Annotations (fingerings, and
  their equivalents on other instruments) are computed from the pitches, not
  read from the page

### The core loop: eight stages

| Stage | What the user does | What the app needs | Where it lives today |
|---|---|---|---|
| **Acquire** | Scans a page, imports ABC or MusicXML, opens a bundled tune, or receives a shared piece | OMR, ABC conversion, share import | `services/omr_service_io.dart`, `homr_flutter`, `abc_converter*`, `piece_share*`, `incoming_share` |
| **Normalize** | Nothing; this is invisible | Repair noisy recognized MusicXML into a single consistent model | `bar_rest_repair`, `meter_repair`, `tuplet_repair`, `musicxml_normalizer`, `musicxml_consistency`, `musicxml_beamer`, then `musicxml_parser` → `ParsedPiece` |
| **Explain** | Picks the view that works for the family | An annotation lane showing *how to make each note* on this instrument; alternative notations (Jianpu); colour by group; section structure (A B A A) | `fingering_mapper`, `fingering_annotation_builder`, `jianpu_converter`, `section_detector`, Verovio + `widgets/staff_view_verovio.dart` |
| **Practise** | Selects a bar or range, loops it, plays it at a slower tempo with a count-in, follows the cursor, prints | Measure hit maps, a scheduler, a count-in, autoscroll | `playback_service_*`, `models/count_in.dart`, `measure_drag_select`, `score_printer` |
| **Annotate** | Writes down what the teacher said, or what went wrong today, on the bar it applies to | Notes anchored to the score, quick stamps, a dated log | **Nothing yet**; see below |
| **Reference** | Records or imports the teacher playing it; taps a bar to hear that bar | Score↔audio alignment, a transport with honest timing | `audio_score_auto_aligner`, `dtw_align`, chroma, `media_playback_service`, `media_transport` (`NativeTransport`) |
| **Tune** | Tunes (or checks pitch) before playing | Pitch detection with instrument-appropriate targets and advice | `packages/string_tuner`, `tuner_model`, `tuner_advice` |
| **Keep** | Builds a library, sees recents, shares with a teacher or another device | Storage, catalog, share bundle, cleanup | `piece_repository`, `piece_library_store`, `piece_activity_store`, `storage_cleanup` |

### The Annotate stage

The app has nothing like this today. The closest existing pieces:

- the measure selection (`widgets/measure_drag_select.dart`)
- the per-piece display prefs
- `PieceActivity.lastSection` (`services/piece_activity_store.dart`), which
  remembers where the player left off

`ParsedPiece.flaggedMeasureNumbers` sounds related but is only a beat-count
check (`models/parsed_piece.dart:524`).

**What a note is:**

```
StudentNote {
  anchor:     piece | section(label) | bars(first, last) | note(bar, index)
  kind:       text | voice | stamp(stampId)
  body:       String / media path
  author:     me | teacher        // "teacher said…", written by the helper
  createdAt:  DateTime
  resolvedAt: DateTime?           // greyed, not deleted
}
```

**Stamps** are one-tap marks for a child who won't type. A small shared set
("slow down", "watch the rhythm", "got it ✓") plus the instrument's own:

- bow lift or retake for strings
- breath mark for winds
- valve or slide reminder for brass
- hand or pedal for piano

The `InstrumentProfile` supplies them, so each app gets a vocabulary that fits.

**Where notes show:**

- **A marker lane on the staff.** The generic lane and tint API that the score
  view needs anyway (see `libraries.md`, `score_view`) draws it, and tapping a
  marker opens the note.
- **A notes list per piece**, filterable to "open".
- **"This week"**: notes by date across pieces, beside the Recents tab
  `PieceActivity` already drives. It doubles as a practice log the helper can
  show the teacher.

**Storage:**

- **A sidecar per piece (`notes.json`)**, never written into the MusicXML. The
  score stays the clean, re-engravable source.
- **Sharing.** The `.stringlings` bundle already carries `sections.json` and
  media beside the score (`services/piece_share_bundle.dart`), so `notes.json`
  rides the same way. It is **opt-in** on share: notes can be personal, and a
  voice note is a child's voice.
- **Dev library.** The sync must learn the file too. The fingerprints are
  computed twice, in `lib/services/dev_library_io.dart` and
  `scripts/pull_dev_library.sh`, and must stay identical
  (`test/dev_library_test.dart`).

**The hard part is anchors surviving edits.** Bars can be inserted or deleted
by `measure_xml_editor`, and a rescan can replace the whole score. Two
requirements follow:

- An edit returns a bar mapping (old index → new index, or deleted), and the
  store remaps its anchors.
- A rescan with no reliable mapping moves the notes to an **orphaned** bucket
  rather than dropping them or pinning them to the wrong bar.

This is the same problem sections already have. Generalizing `Section` into a
neutral `MeasureMarker` (`libraries.md`) solves both together.

**Order:** text notes and stamps first, then voice notes, which reuse the
teacher-recording capture path (`teacher_recording_capture*`). Mock the UI in
an artifact before building, as was done for measure selection.

### Guidance that fades

Every aid the Explain stage adds (note names, fingering labels, diagrams,
group colours, Jianpu) is scaffolding. The goal is a student who reads the
staff. Teachers already worry about this: written-in note names are widely seen
as a crutch, because a student who reads only the labels has not learned to
read music. A few targeted marks, for an alternate fingering or a repeated
mistake, are fine. So the family treats guidance as something that **fades
over time**, not a fixed display mode.

**Two mechanisms, one principle:**

1. **Fading over weeks (per piece, per kind of aid).**
   - The labels move through three stages: on every note, then only on new or
     changed notes, then off.
   - A stage is chosen by the helper or suggested by the app. A suggestion
     could come from how often the piece has been practised
     (`PieceActivity`), or from the Annotate log ("got it ✓" stamps on those
     bars).
   - The ladder is per aid. A violinist might drop note names long before
     string colours.
   - This mirrors the classroom move from note names printed in the
     noteheads to reading without them.
2. **Fading within a moment: guidance on demand.**
   - The staff is shown clean, with no fingering lane.
   - **A tap anywhere on the score brings the fingerings up for a moment.**
     That means the lane, plus the current note in the side bar or tray.
   - They **fade out while the student plays**: after a few seconds, or once
     the cursor has moved on. The help is there exactly when the student is
     stuck, and gone while they read.
   - A tap on a single note keeps that note's full diagram up longer than a
     tap on the background.
   - The fade is a soft animation, not a cut, and respects reduced motion.

**What the design has to get right:**

- **Taps already mean something on the score.** A tap selects a bar
  (`measure_drag_select`), so "show fingerings" needs its own gesture or
  zone. One option is a tap in the lane area, or anywhere during playback,
  when selecting bars is not what the user is doing.
- **Keep the layout still.** The lane must not resize the staff when it
  appears and disappears. Its space stays reserved, or the lane draws over
  the staff margin. (The no-layout-swap rule: a refined layout is never
  swapped in after display.)
- **"While playing" is known from the app's own playback.** It is not yet
  known when the student plays alone. A later version could use the tuner's
  pitch tracker to notice that the student is playing and fade on that.
  Until then, use time since the tap.
- **Store the stage with the piece.** Let the helper see it and reset it; a
  new section of a piece may need the aids back.

This applies to every instrument; only what fades differs.

### The one new abstraction: `InstrumentProfile`

The coupling map found that almost all instrument knowledge goes through a
single hard-coded idea: **a note becomes a G/D/A/E string plus a finger or fret
label.**

- `GdaeTuning.openMidi` (`models/gdae_tuning.dart:14`)
- the first-position lookup table (`assets/engine/lookup_tables/fingering_first_position.json`,
  read by `services/fingering_mapper.dart`)
- `NoteEvent.fingerString` / `fingerNumber` (`models/note_event.dart:111-112`)
- the fixed G/D/A/E colours (`models/violin_string_palette.dart`)

Pitch detection, Jianpu, parsing, layout, alignment and the theme
(`lib/theme`) carry no instrument terms.

The existing seam is `InstrumentFeatures` (`services/instrument_setting.dart:24`):
widgets already ask about capabilities (`fretNumbers`, `tabView`, `chords`),
never about the instrument. The profile grows that into a description of
everything the family varies on:

```
InstrumentProfile {
  id, family, displayName
  transposition      // written − concert, in semitones (B♭ clarinet: +2)   MISSING TODAY
  clefs, writtenRange, comfortableRange                                   MISSING TODAY
  annotator          // (note, context) → {label, groupKey, alternates, diagramRef}
  groupPalette       // colour + stacking order per group (strings, registers, hands, none)
  diagram            // optional widget: chord box, fingering chart, valve icons
  tuner              // targets (open strings | chromatic | a target note),
                     // detector settings (frame, clarity), advice provider
  playback           // GM program; soundfont subset
  alignment          // chroma band, ringSeconds, onsetWeight
  stamps             // the Annotate stage's quick marks
  catalogTags, brand
}
```

- **`annotator`** replaces `fingerString`/`fingerNumber` with
  `{label, groupKey}`. For violin, `label` is `A1` and `groupKey` is `A`.
- **The L/H suffix rule** ("render `A2L` verbatim", CLAUDE.md) becomes a rule
  of the violin annotator, not of the app. Every annotator's labels are
  rendered verbatim.
- **Density** (`models/fingering_density.dart`) keeps its scoring framework.
  Its signals become per-profile: "string change" becomes "group change", and
  the L/H bonus is a violin signal.

### Cross-cutting gaps

Each one blocks one or more groups in Part 2. Costs are S/M/L.

| Gap | Today | Needed by | Cost |
|---|---|---|---|
| **Transposition** (written vs concert pitch) | None. `<transpose>` is only in an element-order list in `measure_xml_editor`; the parser ignores it | Clarinet, saxophone, trumpet, horn, treble-clef baritone | **L**: parser, MIDI, tuner display, annotator key, Jianpu reference |
| **Clef and range** | Not modelled; clefs are only stripped when repeated (`verovio_engraver`) | Viola, cello, bassoon, trombone, tuba, piano | M |
| **Parts, voices and staves** | The parser concatenates every `<measure>` of every part (`musicxml_parser.dart:52`); `<backup>`/`<voice>` ignored; `tab_score_generator.dart:35` "assumes single-voice" | Guitar, piano | **L** |
| **N-string tuning** | `GdaeTuning` only | Viola, cello, bass, guitar, ukulele, banjo | M |
| **Per-instrument alignment parameters** | Chroma band fixed at 180–2600 Hz (`audio_chroma_features.dart:108-109`); `ringSeconds = 1.0` | Low strings, low brass, flute, piccolo, winds generally | S: they are already constructor parameters |
| **Playback program** | `midi_patch.json` `"violin": 40`, read at `playback_service_io.dart:143` | Everyone else | S, plus a soundfont re-cut (`scripts/subset_soundfont.py`) |
| **Annotate** | Not present | Everyone | M |

### How the family is built

The recommendation is **one monorepo, with shared packages and a thin app per
family.**

- Each app has its own store identity: name, icon, art, bundled library and
  first-run flow.
- Within an app, instruments stay a setting, as violin and mandolin are today.

Separate store apps are not cosmetic. A violin app that is only the
multi-instrument app with features removed reads as a near-duplicate under App
Store guideline 4.3 (`docs/instrument-setting-plan.md`, "Later: store
flavors"). A woodwind app with its own characters, its own tunes and a
fingering-chart view is a different product.

The brand also has to be per family. The Stringlings characters are drawn
*as* strings: `ui/stringlings/stringling_climber.dart` climbs a ladder of
G/D/A/E rungs, about 2.2k lines of art code in `lib/ui/stringlings/`. Each
family needs its own art; the rest of the theme system (`lib/theme`, the
classic and playful skins) carries over.

Grouping into apps (a guess, for discussion):

| App | Instruments |
|---|---|
| Strings (Stringlings) | violin, viola, cello, bass; fiddle and mandolin as a setting |
| Fretted | ukulele, guitar, banjo; or folded into Strings |
| Winds | recorder, flute, clarinet, saxophone, oboe, bassoon |
| Brass | trumpet, horn, trombone, euphonium, tuba |
| Keys | piano, later |

---

## Part 2. Specialization by instrument group

Each group lists:

- what carries over unchanged
- what its profile supplies
- the new work
- risks
- a suggested first instrument

Throughout, "carries over" means acquire, normalize, Jianpu, sections,
selection, practice, annotate (with the group's stamps), reference and keep.

### 2.1 Bowed strings: violin, viola, cello, double bass

The cheapest group, and the proof that `InstrumentProfile` works, because it
needs no second app.

- **Annotator:** string + finger, as today. It must extend beyond first
  position for cello and bass, where the table runs out quickly and position
  shifts are the lesson. That means a position-aware chooser, not just a
  bigger table.
- **Group:** the string; colours from the profile.
- **Tuning:** N-string, replacing `GdaeTuning`. The tuner already has viola and
  cello presets (`packages/string_tuner/lib/src/tuning.dart:57,62`).
- **Clef:** alto for viola; bass and tenor for cello. The parser must start
  reading `<clef>`.
- **Alignment:** cello C2 is 65 Hz, far under the 180 Hz band floor. Below
  about 180 Hz a 4096-sample window can't separate semitones, so low
  instruments need a longer window or a constant-Q transform. Harmonics fold
  to the right pitch class, so this is about the low register, not total
  failure.
- **Stamps:** bow lift, retake, slur, "more bow".
- **Library:** the bundled tunes are playable; viola needs alto-clef parts
  (an octave shift plus a clef, generated, not hand-made).
- **Playback:** GM 41 (viola), 42 (cello), 43 (contrabass).
- **First: viola** (one clef, a fifth lower, the same fingering shape). Then
  cello.

### 2.2 Fretted and plucked: mandolin (done), fiddle, ukulele, guitar, banjo

- **Annotator:** string + fret, as the mandolin mode does today
  (`NoteNumberMode.mandolinFret`). Tab view
  (`services/tab_score_generator.dart`) generalizes from 4 to N lines.
- **Chords:** chord symbols already work (`<harmony>`, `chord_palette`,
  `chord_analysis`, all generic). The diagrams (`widgets/chord_diagram.dart`)
  hard-code 4 rows, and `chord_shape_library` is mandolin GDAE: both go
  N-string, with a shape library per tuning.
- **Tuning:**
  - ukulele is **re-entrant** (high G), so "lowest string" logic must not
    assume an ordered tuning
  - banjo has a short 5th string
  - the mandolin's course unison check (`unison_meter.dart`) stays a mandolin
    extra
- **Polyphony:** ukulele melody-plus-chords fits today's model. **Guitar does
  not**: its scores carry real voices. Wait for the parts and voices work.
- **Fiddle:** already planned (`instrument-setting-plan.md`, "Next"): violin
  plus chords, no frets. Close to free.
- **Stamps:** "mute", strum direction, "let ring".
- **First: ukulele.** Then guitar after the parts and voices work.

### 2.3 Woodwinds: recorder, flute, clarinet, saxophone, oboe, bassoon

- **Annotator:** a **fingering-chart lookup** keyed on *written* pitch, with
  alternates. This is the same shape as the violin JSON (`{midi → choice,
  alt}`).
  - The context rule that picks open string vs 4th finger
    (`fingering_mapper.dart`) becomes the place for alternate-fingering rules,
    for example the clarinet's long and short B/C.
  - **The lane label is the note name** (B, A, G), not a hole code. That is
    how woodwind teachers talk: "play B". The fingering is taught once, from a
    chart, and attached to the name. Number shorthand (`T12`, sax `123|1––`)
    belongs to charts and written guides, not to the music, so it is an
    option for adults. Violin is the opposite case: `A1` really is what
    teachers say.
  - The main output is the diagram.
- **Diagram:** a keys-and-holes widget per instrument, the woodwind equivalent
  of `ChordDiagram`. This is the most visible new UI.
  - **The full diagram lives in a side bar** (phone landscape, iPad) **or a
    tray** (phone portrait). It shows the current note: the tapped note, or
    the cursor's note during playback.
  - It says what changes from the last note ("Put down left 2 · Lift
    thumb"). That matches how a new note is introduced in class ("thumb and
    1"), and a parent can read it aloud.
  - Small diagrams over the notes are drawn only on big changes.
  - Mockup: [Woodwind fingering lane](https://claude.ai/artifact/CsAVDqn3rDNvxmDdnbS6qr)
    (private until shared).
- **Group:** register (the clarinet's chalumeau, throat and clarion; the
  octave key on sax, oboe and flute). The colour lane shows "you changed
  register here", which is where beginners fail.
- **Transposition:**
  - clarinet B♭ (written is 2 semitones above concert)
  - alto sax E♭ (+9)
  - tenor sax B♭ (+14)
  - recorder, flute and oboe are non-transposing

  This is the group that forces the transposition gap to be solved.
- **Tuner:** chromatic, showing **written** pitch. Breathy tone lowers YIN
  clarity, so the clarity threshold becomes a profile setting. The advice is
  about the barrel, the mouthpiece or the head joint, not pegs.
  `TunerModel`'s onset and attack logic (`services/tuner_model.dart`) is tuned
  for plucks and bows, and needs a sustained-tone segmenter.
- **Alignment:**
  - **`ringSeconds` near 0**: winds stop dead, unlike a ringing string
  - **raise the band top** for flute and piccolo, which reach above 2.6 kHz
  - **tune `onsetWeight`**: tongued attacks are clear, but slurred legato
    gives weak onsets
- **Stamps:** breath mark, "tongue", "slur", "octave key".
- **Playback:** GM 74 (recorder), 73 (flute), 71 (clarinet), 65 (alto sax),
  68 (oboe), 70 (bassoon).
- **Library:** the bundled public-domain tunes need transposed written parts
  for B♭ and E♭ instruments, generated from the concert score.
- **Copyright:** band method books are the norm here, and the content rule is
  the same as for violin. Never name a method, edition or its numbering; say
  "band method book".
- **First: recorder or flute** (non-transposing, treble clef, simple chart).
  Then **clarinet**, to prove transposition end to end.

### 2.4 Brass: trumpet, horn, trombone, euphonium, tuba

- **Annotator:** valve combination (0, 2, 1, 12, 23, 13, 123) or slide
  position (1–7), chosen per note.
  - The real teaching content is the **partial**: the same valves give
    several notes.
  - So `groupKey` is the partial, and the colour lane shows the leaps between
    partials, which are what beginners crack.
- **Diagram:** three (or four) valve icons; a slide ruler for trombone.
- **Transposition:**
  - trumpet B♭ (+2)
  - horn F (+7)
  - euphonium in treble clef B♭ (+14); in bass clef it is non-transposing
  - trombone and tuba are non-transposing
- **Clef:** bass for trombone, euphonium and tuba.
- **Tuner:**
  - chromatic, with written pitch
  - tuba fundamentals are 30–40 Hz, so a 2048-sample frame at 48 kHz is too
    short; the frame length becomes a profile setting
  - advice is about the main slide and the embouchure
- **Alignment:** the low-band work from §2.1 again, plus the wind settings
  from §2.3 (no ring).
- **Stamps:** breath mark, valve reminder, "lip slur", "buzz first".
- **Playback:** GM 56 (trumpet), 60 (horn), 57 (trombone), 58 (tuba).
- **First: trumpet** (treble clef, three valves; it shares the transposition
  work with clarinet).

### 2.5 Keyboard: piano

The largest structural lift, so it comes last.

- **Score model:** a grand staff, two hands, chords and voices. This depends
  entirely on the parts, voices and staves work.
- **Fingering injection:** pairs notes with XML by document order
  (`fingering_xml_injector.dart`), which breaks with two staves.
- **Annotator:** finger numbers 1–5 per hand. Good piano fingering is a search
  problem (hand position, crossings), not a lookup, and it is the hardest
  annotator in the family. A first cut can show only the fingerings the score
  already has (`NoteEvent.scoreFinger`) plus simple five-finger-position
  suggestions.
- **Group:** the hand (left or right).
- **No tuner.** A pitch check is optional.
- **Alignment:** works well. The score chroma reference already sums chord
  notes per pitch class, and piano decay suits the existing `ringSeconds`.
- **Practice extras:** hands-separate playback and muting one hand in the
  synth. These are new scheduler features.
- **Stamps:** "hands separate", pedal, "watch thumb".
- **Playback:** GM 0.
- **First:** a single piano profile with right hand only, as a stepping stone,
  only if a family asks for it before the voices work lands.

### 2.6 Voice (optional)

There is no annotator and no diagram: solfège or Jianpu is the
"how to make it". The tuner is chromatic and the range is per voice type.
Lyrics already engrave (`lyric_xml_injector`), with the repo's rule on
copyrighted lyrics unchanged. It is cheap once the profile exists, and a
natural setting in any app rather than its own app.

---

## Open questions

1. **App grouping:** are Fretted and Strings one app (the Stringlings brand
   already covers mandolin), or two?
2. **First non-string instrument:** recorder (simplest; common in school) or
   flute? Both are non-transposing.
3. **Notes on share:** opt-in per share (proposed), or a per-piece setting?
4. **Voice notes:** keep them device-only even in the dev library, given that
   it is a child's voice?
5. **Transposition model:** store concert pitch in `NoteEvent` and derive
   written pitch, or the reverse? The proposal is concert, because alignment,
   playback and the tuner all work in concert; only display and annotation
   want written.
6. **Fading guidance:** which gesture brings the fingerings up, given that a
   tap already selects a bar? And should the app suggest the next fade
   stage, or only the helper decide?
