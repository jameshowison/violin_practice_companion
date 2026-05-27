# Phase 1: MusicXML → Display

## Goal

Build all notation display modes and piece navigation UI using clean MusicXML
fixtures. No camera, no playback. At the end of Phase 1 a parent can load a
piece, switch between staff / jianpu / fingering views, and select measures or
sections for targeted practice.

---

## Stack

| Concern | Choice |
|---------|--------|
| Framework | Flutter 3.x |
| State management | Riverpod |
| MusicXML parsing | Dart `xml` package |
| Staff rendering | OSMD (OpenSheetMusicDisplay) bundled in `webview_flutter` |
| Jianpu rendering | Custom `CustomPainter` |
| Fingering rendering | Custom `CustomPainter` |
| Storage | `path_provider` + JSON files |

OSMD **must be bundled as a local asset**, not loaded from CDN. The app is
fully offline.

---

## Project Structure

```
lib/
  main.dart
  app.dart
  models/
    piece.dart
    section.dart
    parsed_piece.dart
    note_event.dart
  services/
    musicxml_parser.dart
    jianpu_converter.dart
    fingering_mapper.dart
    piece_repository.dart
  widgets/
    staff_view.dart
    jianpu_view.dart
    fingering_view.dart
    measure_selector.dart
    section_bar.dart
    notation_switcher.dart
  screens/
    piece_list_screen.dart
    piece_detail_screen.dart
assets/
  fixtures/
    lightly_row.xml
    bach_minuet_1.xml
    bach_minuet_2.xml
    bach_minuet_3.xml
    happy_farmer.xml
    gavotte_gossec.xml
    sections/
      lightly_row_sections.json
      bach_minuet_1_sections.json
      bach_minuet_2_sections.json
      bach_minuet_3_sections.json
      happy_farmer_sections.json
      gavotte_gossec_sections.json
  lookup_tables/
    jianpu_key_map.json
    fingering_first_position.json
    open_string_preferences.json
  osmd/
    opensheetmusicdisplay.min.js
    osmd_bridge.html
```

---

## Copyright-Clean Fixtures

**All fixture MusicXML files must be verified public domain before commit.**

The following pieces are safe — all are public domain melodies commonly found
in beginner violin method books. Do not use MuseScore files that encode
publisher-specific bowings, fingerings, or articulation marks — strip these
before committing, or enter the notes manually in MuseScore and export fresh.

| File | Piece | Composer | PD Status |
|------|-------|----------|-----------|
| `lightly_row.xml` | Lightly Row | Folk song | PD |
| `bach_minuet_1.xml` | Minuet in G minor, BWV Anh. 114 | attr. Bach (J.S.) | PD |
| `bach_minuet_2.xml` | Minuet in G, BWV Anh. 116 | attr. Bach (J.S.) | PD |
| `bach_minuet_3.xml` | Minuet in C, BWV Anh. 114 | attr. Bach (J.S.) | PD |
| `happy_farmer.xml` | The Happy Farmer, Op.68 No.10 | Schumann | PD |
| `gavotte_gossec.xml` | Gavotte | Gossec | PD |

**Twinkle Twinkle Little Star is intentionally excluded from fixtures.**
It will be the first piece tested via the Phase 3 OMR scanning pipeline.

**What to strip from MuseScore exports before committing:**
- `<fingering>` elements
- `<technical>` elements (bowing, up-bow, down-bow)
- `<articulation>` elements specific to any published edition
- Any `<direction>` text that reproduces editorial commentary

Keep: notes, rhythms, key signature, time signature, slurs, dynamics if
originally part of the public domain score.

---

## Lookup Tables

**All lookup tables live in `assets/lookup_tables/` as JSON files.
No magic numbers or pitch mappings may appear in Dart source code.**

This is a hard rule. When a teacher or parent wants to change a fingering
convention — for example, changing a "low 3" to a "3" — that is a single
edit in one JSON file, not a code change. The Dart services load these tables
at startup and treat them as configuration.

### `jianpu_key_map.json`

Maps MusicXML `fifths` values to tonic pitch class and scale degree sequence.

```json
{
  "comment": "Maps MusicXML key fifths to tonic and scale degrees (chromatic pitch classes 0-11, C=0)",
  "keys": {
    "-4": { "tonic": "Ab", "tonicPc": 8,  "scale": [8,10,0,1,3,5,7] },
    "-3": { "tonic": "Eb", "tonicPc": 3,  "scale": [3,5,7,8,10,0,2] },
    "-2": { "tonic": "Bb", "tonicPc": 10, "scale": [10,0,2,3,5,7,9] },
    "-1": { "tonic": "F",  "tonicPc": 5,  "scale": [5,7,9,10,0,2,4] },
    "0":  { "tonic": "C",  "tonicPc": 0,  "scale": [0,2,4,5,7,9,11] },
    "1":  { "tonic": "G",  "tonicPc": 7,  "scale": [7,9,11,0,2,4,6] },
    "2":  { "tonic": "D",  "tonicPc": 2,  "scale": [2,4,6,7,9,11,1] },
    "3":  { "tonic": "A",  "tonicPc": 9,  "scale": [9,11,1,2,4,6,8] },
    "4":  { "tonic": "E",  "tonicPc": 4,  "scale": [4,6,8,9,11,1,3] }
  }
}
```

### `fingering_first_position.json`

Maps MIDI note numbers to first-position string and finger assignments.
Middle C = MIDI 60. G3 = MIDI 55.

The `finger` field uses string labels to make variants explicit and editable:
- `"0"` = open string
- `"1"`, `"2"`, `"3"`, `"4"` = standard finger
- `"1low"`, `"2low"`, `"3low"` = low (flattened) variant of finger

```json
{
  "comment": "First-position violin fingering. MIDI note → preferred and alternate fingerings. Edit finger labels here; do not change logic in fingering_mapper.dart.",
  "notes": {
    "55": { "string": "G", "finger": "0",    "alt": null },
    "56": { "string": "G", "finger": "1low", "alt": null },
    "57": { "string": "G", "finger": "1",    "alt": null },
    "58": { "string": "G", "finger": "2low", "alt": null },
    "59": { "string": "G", "finger": "2",    "alt": null },
    "60": { "string": "G", "finger": "3low", "alt": null },
    "61": { "string": "G", "finger": "3",    "alt": null },
    "62": { "string": "G", "finger": "4",    "alt": { "string": "D", "finger": "0" } },
    "63": { "string": "D", "finger": "1low", "alt": null },
    "64": { "string": "D", "finger": "1",    "alt": null },
    "65": { "string": "D", "finger": "2low", "alt": null },
    "66": { "string": "D", "finger": "2",    "alt": null },
    "67": { "string": "D", "finger": "3",    "alt": null },
    "68": { "string": "D", "finger": "3",    "alt": null },
    "69": { "string": "D", "finger": "4",    "alt": { "string": "A", "finger": "0" } },
    "70": { "string": "A", "finger": "1low", "alt": null },
    "71": { "string": "A", "finger": "1",    "alt": null },
    "72": { "string": "A", "finger": "2low", "alt": null },
    "73": { "string": "A", "finger": "2",    "alt": null },
    "74": { "string": "A", "finger": "3",    "alt": null },
    "75": { "string": "A", "finger": "3",    "alt": null },
    "76": { "string": "A", "finger": "4",    "alt": { "string": "E", "finger": "0" } },
    "77": { "string": "E", "finger": "1low", "alt": null },
    "78": { "string": "E", "finger": "1",    "alt": null },
    "79": { "string": "E", "finger": "2low", "alt": null },
    "80": { "string": "E", "finger": "2",    "alt": null },
    "81": { "string": "E", "finger": "3",    "alt": null },
    "82": { "string": "E", "finger": "3",    "alt": null },
    "83": { "string": "E", "finger": "4",    "alt": null }
  }
}
```

**Note:** MIDI 67 and 68 both currently map to `D3`. This covers G4 and Ab4/G#4
on the D string. A violin teacher should verify the correct finger label for
Ab4 before the table is considered final.

### `open_string_preferences.json`

Controls which fingering is chosen when a note has both a fingered and open
string option. This is a user preference that can be toggled in settings.

```json
{
  "comment": "When a note can be played as an open string or a fingered note on a lower string, which is preferred? 'open' = prefer open string; 'fingered' = prefer fingered (richer tone, typical for advancing students).",
  "default": "fingered"
}
```

`fingering_mapper.dart` reads this value at runtime. The settings screen writes
it back. No other file references this preference.

---

## Data Models

```dart
class Piece {
  final String id;
  final String title;
  final String musicXmlPath;
  final List<Section> sections;
}

class Section {
  final String label;       // "A", "B", "C" etc.
  final int startMeasure;   // 1-indexed, inclusive
  final int endMeasure;     // 1-indexed, inclusive
}

// In-memory only — derived from MusicXML parse
class ParsedPiece {
  final String keySignature;
  final int keyFifths;
  final KeyMode keyMode;
  final List<Measure> measures;
}

class Measure {
  final int number;
  final List<NoteEvent> notes;
}

class NoteEvent {
  final String pitch;          // e.g. "D5", "A4", "R" for rest
  final int midiNumber;        // e.g. 74 — computed from pitch+octave
  final int octave;
  final NoteValue noteValue;
  final bool dotted;
  final bool isRest;
  final int? scoreFinger;      // from score markup, may be null
  // Computed by services, not from MusicXML:
  final int? jianpuNumber;     // 1-7
  final int? jianpuOctaveDots; // positive=above, negative=below
  final String? fingerString;  // "G","D","A","E"
  final String? fingerNumber;  // "0","1","1low","2","2low","3","3low","4"
}

enum NoteValue { whole, half, quarter, eighth, sixteenth }
enum KeyMode { major, minor }
enum DisplayMode { staff, jianpu, fingering, combined }
```

---

## Services

### `musicxml_parser.dart`

Parses a MusicXML string into `ParsedPiece`. Uses the Dart `xml` package.

Extracts:
- `//key/fifths` → `keyFifths`
- `//key/mode` → `keyMode`
- Each `//measure` → `Measure` with `number` attribute
- Each `//note` inside a measure:
  - `//pitch/step` + `//pitch/octave` + `//pitch/alter` → `pitch`, `octave`, `midiNumber`
  - `//type` → `noteValue`
  - `//dot` presence → `dotted`
  - `//rest` presence → `isRest`
  - `//notations/technical/fingering` → `scoreFinger` if present

Does **not** parse bowings, articulations, or dynamics.

### `jianpu_converter.dart`

Input: `ParsedPiece`
Output: same `ParsedPiece` with `jianpuNumber` and `jianpuOctaveDots` populated
on each `NoteEvent`.

Loads `assets/lookup_tables/jianpu_key_map.json` at startup.

Algorithm:
1. Look up `keyFifths` in the key map to get the scale (list of 7 pitch classes)
2. For each note, find its pitch class in the scale → `jianpuNumber` (1-indexed)
3. If pitch class is not in the scale (accidental), find nearest scale degree
   and set a `#` or `b` modifier (extend `NoteEvent` if needed)
4. Determine reference octave: the octave containing the tonic
5. `jianpuOctaveDots` = `note.octave - referenceOctave`

### `fingering_mapper.dart`

Input: `ParsedPiece`
Output: same `ParsedPiece` with `fingerString` and `fingerNumber` populated.

Loads `assets/lookup_tables/fingering_first_position.json` and
`assets/lookup_tables/open_string_preferences.json` at startup.

Algorithm:
1. Look up `midiNumber` in the fingering table
2. If `alt` is present and user preference is `"open"` and `alt.finger == "0"`,
   use the alt (open string) entry; otherwise use the primary entry
3. If `alt` is present and user preference is `"fingered"` and
   primary `finger == "0"`, use the alt entry
4. Write `fingerString` and `fingerNumber` onto the `NoteEvent`

Display format: `"${fingerString}${fingerNumber}"` e.g. `"A1"`, `"D0"`, `"E2low"`.
The UI may render `"low"` variants as a subscript or small annotation — that is
a rendering decision, not a data decision.

### `piece_repository.dart`

Loads pieces from `assets/fixtures/` at startup.
Also watches app documents directory for user-imported pieces (Phase 3).

---

## Staff View (`staff_view.dart`)

WebView wrapping OSMD. OSMD is loaded from bundled assets only.

`assets/osmd/osmd_bridge.html`:
```html
<!DOCTYPE html>
<html>
<head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body>
<div id="osmd-container"></div>
<script src="opensheetmusicdisplay.min.js"></script>
<script>
  const osmd = new opensheetmusicdisplay.OpenSheetMusicDisplay('osmd-container');
  window.loadScore = async (xml) => {
    await osmd.load(xml);
    osmd.render();
  };
  window.highlightMeasure = (n) => { /* use OSMD cursor API */ };
  window.clearHighlight = () => { /* clear cursor */ };
</script>
</body>
</html>
```

Flutter communicates via:
- `webViewController.runJavaScript('window.loadScore(...)')`
- `JavascriptChannel` named `OsmdBridge` for error callbacks

---

## Jianpu View (`jianpu_view.dart`)

`CustomPainter` implementation. Renders jianpu notation from a list of
`NoteEvent`s with jianpu fields populated.

Layout rules:
1. Left-to-right within a measure
2. Barlines between measures
3. Line wrap at widget width
4. Section label (e.g. "A") printed above the first measure of each section
5. Octave dots: rendered as small dots above or below the number
   (one dot per octave step, stacked vertically)
6. Duration underlines: drawn below the number
   (eighth = 1 line, sixteenth = 2 lines)
7. Dotted notes: small dot to the right of the number
8. Rests: use standard jianpu rest symbol (0)

Each measure is a tappable region for `MeasureSelector` integration.
Selected measures render with a background highlight.

---

## Fingering View (`fingering_view.dart`)

Same layout engine as `jianpu_view.dart`. Shares the measure/line layout logic
(extract to a `NotationLayoutEngine` base class or mixin).

Renders `"${fingerString}${fingerNumber}"` where the number is in a slightly
smaller font if it contains "low" — or renders the base number with a `b`
subscript. Exact rendering of "low" variants is a UI decision; keep it
consistent and legible at small sizes.

Combined mode: jianpu number on the upper line, fingering on the lower line,
sharing the same measure grid.

---

## Measure Selector (`measure_selector.dart`)

Horizontal scrollable row of numbered boxes, one per measure.

- Single tap: select that measure
- Tap-and-drag or tap two measures: select a range
- Section labels appear above their measure ranges
- Selected range shown with highlight color
- "Clear selection" tap on already-selected measure

Emits `MeasureSelection(startMeasure, endMeasure)` to parent via callback or
Riverpod state. Phase 1: selection state is tracked but triggers nothing.
Phase 2: selection drives loop playback.

---

## Screens

### `PieceListScreen`

List of available pieces loaded from `PieceRepository`.
Each item shows title. Tapping navigates to `PieceDetailScreen`.

### `PieceDetailScreen`

```
┌─────────────────────────────────┐
│  [Staff] [Jianpu] [Finger] [+]  │  ← NotationSwitcher tabs
├─────────────────────────────────┤
│                                 │
│   Active notation view          │  ← scrollable
│                                 │
├─────────────────────────────────┤
│  A:1-4  B:5-8  A:9-12  A:13-16 │  ← SectionBar
│  [1][2][3][4][5][6][7]...       │  ← MeasureSelector
└─────────────────────────────────┘
```

Settings drawer (swipe or gear icon):
- Open string preference toggle: "Prefer open strings / Prefer fingered"

---

## Localisation

Add `flutter_localizations` and ARB files from the start.

```
lib/l10n/
  app_en.arb
  app_zh.arb
```

All user-visible strings go through `AppLocalizations`. Jianpu numbers and
fingering notation (A1, D2 etc.) are not localised — they are notation, not
text.

---

## Phase 1 Acceptance Criteria

- [ ] All 6 fixture pieces load without error
- [ ] Staff view renders correctly for all fixtures via OSMD
- [ ] Jianpu numbers are correct for D major and A major pieces
- [ ] Jianpu octave dots are correct across the note range of each piece
- [ ] Fingering mode shows correct string+finger for all notes in first position
- [ ] Open string preference toggle changes fingering output correctly
- [ ] Combined mode shows both jianpu and fingering aligned per note
- [ ] Section labels appear correctly above measures
- [ ] Measure selector correctly highlights selected range in all views
- [ ] Changing notation mode preserves selected measure range
- [ ] App runs fully offline — no network calls at any point
- [ ] Flutter web build runs in Chrome and Safari mobile
- [ ] Unit tests pass for `musicxml_parser`, `jianpu_converter`, `fingering_mapper`
- [ ] All lookup tables are JSON assets; no pitch or fingering data appears in
      Dart source code
