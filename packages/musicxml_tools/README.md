# musicxml_tools

MusicXML in pure Dart, with no Flutter and no platform code.

- **Model:** `ParsedPiece` → `Measure` → `NoteEvent`, a single melodic line
  with chords, ties, tuplets, lyrics, repeats, endings and navigation marks.
  `NoteEvent.annotation` carries whatever an app works out about a note (a
  fingering, a Jianpu digit) without the model reading it.
- **`MusicXmlParser`:** MusicXML text to `ParsedPiece`, with the opening
  `Clef` and `Transpose` (read, not applied).
- **`MeasureXmlEditor`:** writes a bar's notes back into the MusicXML,
  keeping what it doesn't model (grace notes, notations).
- **Repairs**, each MusicXML text to MusicXML text, for scores read by optical
  music recognition: `BarRestRepair`, `MeterRepair`, `TupletRepair`,
  `MusicXmlNormalizer`, `MusicXmlConsistency`, `MusicXmlBeamer`.
- **Injectors and generators:** `ChordXmlInjector`, `LyricXmlInjector`,
  `FingeringXmlInjector`, `buildPreambleXml`.
- **Interchange:** `AbcExporter`; `JianpuDigits`, with its key table passed in.

Written for [Stringlings](../../README.md), and extracted from it
(`docs/libraries-migration.md`). Licence: GPL-3.0.

```dart
import 'package:musicxml_tools/musicxml_tools.dart';

final piece = MusicXmlParser().parse(xml);
for (final m in piece.measures) {
  print('${m.number}: ${m.notes.map((n) => n.pitch).join(' ')}');
}
```

Tests: `dart test` here, or `bash scripts/test_all.sh` from the repo root.
