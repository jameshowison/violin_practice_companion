# Source, instrument, player: three layers for a piece

Status: proposal, 2026-11-21. Nothing here is built. It replaces step 2 of
[`libraries.md`](libraries.md) ("`InstrumentProfile`, proved with viola")
with a data model that step needs first.

## Why

Two requests led here:

- **A viola player should read alto clef**, while the bundled pieces are
  violin parts in treble clef.
- **A family may share one app across several children,** each with their
  own instrument and their own notes on the music.

Both say the same thing: a piece is not one object. It is:

1. **Source:** the music as it was acquired, in the clef it was written in.
   A scan of a treble part stays treble; a scan of a viola part stays alto.
   It is shared by everyone.
2. **Instrument:** how that music is shown and played on one instrument. The
   clef and octave, fingerings and the choices behind them, the playback
   sound. It is derived from the source, plus a small set of overrides per
   instrument.
3. **Player:** one child's relationship to the piece. Their instrument,
   their view settings, their notes (Annotate), their practice history and
   how far their guidance has faded.

## The rule that makes it safe

**Only the source is ever written as a score.** Each instrument view is a
pure function, `view(sourceXml, profile, overrides)`, and is never saved.
The view's engraving and rendered audio are cached by their own content, as
today; both caches already hash the exact XML and note schedule.

An edit made while looking at a view is **mapped back** before it is saved:

- an octave or clef change is exactly invertible
- a note entered on the viola staff at C3 is stored as the source's C4 when
  the source is a violin part

This is the one hazard the inventory found that would corrupt data. The
measure editor saves whatever `parsedPieceProvider` parsed
(`measure_edit_session.dart:670-720`). So the view must live in its own
providers, and the editor must keep reading the source, with the inverse
applied to its input and output.

## What goes where

From an inventory of everything the app persists today:

| Today | Stored as | Layer |
|---|---|---|
| The score (`scanned_pieces/<id>.musicxml`, `editable_fixtures/`) | a file per piece | **Source** |
| Sections (`section_overrides/`) | a file per piece | **Source**. They point at measure plus note, so they survive a change of clef or octave, but not re-barring |
| Recordings, trims, offsets (`media/`, `pieceMedia.<id>`) | files and a pref | **Source** |
| Alignments (`mediaAlignment.*`) | a pref per medium | **Source**. Chroma ignores octave, so a viola view reuses the violin alignment |
| ABC and scan originals | files | **Source** (provenance) |
| The pinned performance tempo (`tempo.piece.<id>`) | a pref | **Source**, as the piece's tempo. A child's working tempo is the player's |
| **Open or 4th-finger choices, written into the score as `<fingering>` 0/4** | **inside the source XML** | **Instrument.** Moves out of the score: see migration |
| `display.violinStrings`, `display.fretStyle` | per-piece prefs | **Instrument** |
| `display.numbers` (the per-piece violin/mandolin picker) | a per-piece pref | gone: the **player's** instrument decides the view |
| Staff zoom, view mode, colours, note names, fingering detail, chords switch, lyric verse | per-piece prefs | **Player** |
| Tempo presets, count-in, skin, left-handed tuner | app-wide prefs | **Player** |
| Recents and last section (`pieceActivity`) | an app-wide pref | **Player** |
| Notes from the teacher (Annotate, not built) | nothing yet | **Player** |
| Tuner reference A (440 or 442) | an app-wide pref | **Player**: it follows the child's teacher |
| Speaker calibration, video-shrink bookkeeping, dev-sync base | prefs | **Device**, in none of the layers |
| The library: collections, hidden pieces | one pref | shared by the family. Per-player hiding can come later |

## The instrument layer

An `InstrumentProfile` (as in [`approach.md`](approach.md)) supplies:

- **Reading clef and octave.** Violin, mandolin: treble at sounding pitch.
  Viola: alto. Cello: bass, with tenor later.
- **The transcription from any source clef.** A source in treble becomes alto
  for viola, an octave down. A source already in alto is shown as it is. A
  source in alto is shown to a violin an octave up, in treble. The octave is
  chosen so the tune falls in the instrument's first-position range, and is
  only ever a whole number of octaves, so chroma alignments stay valid.
- **Fingering:** a first-position table and the string names. Viola's table
  is the violin's a fifth lower, with C/G/D/A in place of G/D/A/E, so the
  L/H labels carry over (`D2L` is viola's F♮).
- **Playback program:** GM 41 for viola. The soundfont cut gains that bank.
- **Tuning** for the tuner: `packages/string_tuner` already has the viola.

**Instrument overrides** are stored **per piece, per instrument**, keyed by
note (measure, index). They replace the `<fingering>` 0/4 that the editor
writes into the score today, plus `violinStrings` and `fretStyle`. A score
can still carry fingerings of its own (the catalog's `fingerings: app |
cleared`); those remain source data.

## The player layer

- **A player** has an id, a name, an instrument and a colour or avatar.
- **A family with one child** never sees players: the app behaves exactly as
  now. Adding a second child shows a switcher, perhaps beside the title.
- **Player prefs** are today's per-piece `display.*` keys and the app-wide
  practice settings, re-keyed by player. On first launch, everything that
  exists becomes the first player's.
- **The Instruments setting becomes the player's instrument:** violin, viola
  or mandolin, each separate. Mandolin is no longer bundled with violin.
  Chords and the tab view follow the instrument (mandolin), unless a setting
  turns chords on for violin (the fiddle idea).

## Sharing and the dev library

- **A `.stringlings` share carries the source** (score, sections, chosen
  recordings and alignments). Optionally it also carries the sender's
  **instrument overrides for the instrument the receiver plays**. It never
  carries player data: notes stay with the child unless explicitly shared
  (Annotate's open question).
- **The dev library syncs source and instrument layers.** Today's
  `display:numbers` and `display:fretStyle` entries become instrument
  overrides, and the Dart and Python fingerprints change together.

## Migration, in steps that each ship

1. **The layer seam, without a second instrument.**
   - Add `InstrumentProfile` (violin and mandolin), the view function, and
     the view's own providers.
   - The editor reads and writes through the inverse, which is the identity
     for now.
   - The migration snapshot must not move.
2. **Instrument overrides out of the score.**
   - On first launch, the `<fingering>` 0/4 that the app itself wrote (on
     D4, A4 and E5) move into the violin overrides.
   - The score keeps any fingering it came with. To tell them apart, the
     catalog's `fingerings` field says whether a bundled score had its own;
     a scanned or imported score's 0/4 on those notes counts as the app's.
   - The share bundle and the dev library carry overrides.
3. **Viola:**
   - the profile
   - the alto transcription and its inverse in the editor
   - the C/G/D/A palette and table
   - the GM 41 soundfont cut
   - the tuner preset as default
   - "Viola" in Settings
4. **Players:**
   - the model
   - re-keying prefs, with the first player inheriting everything
   - the switcher
   - per-player activity
   - Mandolin as its own instrument choice
5. **Annotate**, now a player-layer feature (deferred for now).

Each step keeps Stringlings shipping. Step 1 changes nothing visible. Steps
3 and 4 are the user-visible ones, and need a check on a device by a viola
player, and a family test of the switcher.

## Open questions

1. **Normalization on open:** opening a piece runs the repairs and saves the
   result over the stored file (`piece_repository.dart:144-172`). So the
   "source" is already normalized, and an imported MusicXML keeps no
   original. Keep that (the repairs are lossless fixes), or keep the original
   file beside the normalized one, as scans and ABC already do?
2. **Octave choice:** decide it per piece by range, the proposal, or fix it
   per pair of instruments (violin source → viola is always an octave down)?
   Per piece is more often playable. Fixed is more predictable for a teacher
   comparing parts.
3. **Players and recordings:** a teacher's recording is shared. Is one child's
   own practice recording theirs (player) or the family's (source)?
4. **The tempo pin:** is it the piece's tempo (source, proposed), or each
   child's goal (player)?
