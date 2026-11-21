# score_view

Engraving MusicXML with [Verovio](https://www.verovio.org) in Flutter. For
now this is the engraving layer only; the staff widget that draws it is
still in the app (`docs/family/libraries.md`, "2. score_view").

- **`VerovioEngraver`:** `engrave()` lays a MusicXML string out at a width
  and staff size and returns an `EngravedScore`: the SVG (flattened for
  `jovial_svg`), bounding boxes, measure and note anchors, line bands, the
  engraved fingering and chord anchors, voltas, and `measureAt`/`noteAt`.
  That is the tap-to-measure hit map. Results are cached in memory and on
  disk; set `engraveCacheStamp` to your build's stamp before the first
  engrave, so a new build doesn't read an old build's entries.
- **SVG passes,** static on `VerovioEngraver`: `stripAnnotationGlyphs`,
  `stripEndings`, `stripMeasureNumbers`, `clefFirstSystemOnly`,
  `flattenForRenderer`, `colourNoteheads`, `systemInkBoxes`,
  `measureStaffLines` and others.
- **`staff_zoom`:** staff sizes in millimetres on a phone or tablet, the
  measures-per-line and scale math, the annotation-room reserve, and the
  staff-spacing slider's range (`staffSpacingMin`/`Max`/`Default`).
- **Section layout:** `planSectionLines` (every section on whole lines, of
  even width), `solveSectionLayout` and `sectionFitCandidates`.
- **System breaks:** `insertBreaksAtPositions`, `systemStartPositions`, and
  the parts other break passes share (`AttrState`, `insertPrintBreak`,
  `hidePreamble`).
- **Print:** `paginateLines` splits engraved systems into pages.

It is Flutter only through `dart:ui` geometry and `verovio_flutter`, with no
state management. The disk cache uses `dart:io` and `path_provider`, behind
`engrave_disk_cache.dart`.

Written for [Stringlings](../../README.md), and extracted from it
(`docs/libraries-migration.md`). Licence: GPL-3.0.

Tests: `flutter test` here, or `bash scripts/test_all.sh` from the repo root.
