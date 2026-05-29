# Phase 3: Section Metadata Editor

## Prerequisites

Phase 2 complete. The following are assumed stable:

- `PlaybackService` interface and `currentMeasure` stream
- `SectionBar` and `MeasureSelector` widgets reading sections from `Piece.sections`
- `PieceRepository.loadAll()` returning `Piece` objects with sections from asset bundle
- JSON sidecar format from Phase 1 fixtures (see below)

## Goal

Let parents edit the section structure of a piece (which measures belong to
section A, B, etc.) directly in the app, without touching JSON files. Edited
sections override the fixture default and persist across restarts.

---

## Section Metadata Editor (`section_metadata_editor.dart`)

Accessible via an **"Edit sections"** button on `PieceDetailScreen`.

**UI:**
- Scrollable row of numbered measure boxes (same visual language as `MeasureSelector`)
- Tap a measure to designate it as the start of a new section
- A text field appears to enter the section label (A, B, C, or any short string)
- Existing section starts are shown with their label above the measure box
- A "clear" action removes a section boundary
- "Save" button commits the changes; "Cancel" discards

**Persistence:**
- Save writes a JSON sidecar to `{documentsDir}/sections/{pieceId}_sections.json`
- Format is identical to the fixture sidecar:
  ```json
  {
    "sections": [
      { "label": "A", "startMeasure": 1, "endMeasure": 4 },
      { "label": "B", "startMeasure": 5, "endMeasure": 8 }
    ]
  }
  ```
- `endMeasure` for each section is derived automatically: it is one less than
  the next section's `startMeasure`, or the last measure of the piece for the
  final section

**`PieceRepository` changes:**
- After loading from asset bundle, check for a user sidecar at
  `{documentsDir}/sections/{pieceId}_sections.json`
- If present, replace the asset-bundle sections with the user sidecar
- This override logic lives in `PieceRepository`, not in the editor widget

**Live update:**
- After save, the Riverpod piece provider must re-emit the updated `Piece`
- `SectionBar` and `MeasureSelector` rebuild from the new sections without a
  full app restart

---

## Phase 3 Acceptance Criteria

- [ ] "Edit sections" button is visible on `PieceDetailScreen`
- [ ] Editor opens showing all measures with current section boundaries marked
- [ ] Adding and removing section boundaries works correctly
- [ ] Saving persists to `{documentsDir}/sections/{pieceId}_sections.json`
- [ ] Edited sections survive an app restart
- [ ] `SectionBar` and `MeasureSelector` update immediately after save (no restart needed)
- [ ] If no user sidecar exists, fixture default is used unchanged
- [ ] Multi-platform smell check passes — file I/O goes through `path_provider`;
      no `dart:io` in shared widget code

---

## Considered But Decided Against

### Bouncing Ball Mode

A sub-beat visual indicator where a ball moves horizontally across each measure
in proportion to elapsed time:

```
positionInMeasure = (elapsedSeconds − measureOnsetSeconds[m])
                  / measureDurationSeconds[m]
```

Rendered as an `AnimatedPositioned` overlay on the notation view; would require
`PlaybackService` to expose `measureOnsetSeconds` and `measureDurationSeconds`
as additional API surface.

**Why not:** Measure highlight already tells a non-music-reading parent where
the piece is. The bouncing ball adds widget complexity and expands the
`PlaybackService` API without clear benefit for the target user. It also cannot
be used in staff view (OSMD WebView), creating an inconsistent experience across
notation modes. Could be revisited if user testing shows demand for sub-beat
positioning feedback.

---

## Deferred to Phase 4

The teacher video pipeline originally planned as Phase 2B:

- Video import and file storage (`file_picker`, `ffmpeg_kit_flutter`)
- Audio-to-score alignment: chroma feature extraction (`fftea`) + DTW
- Alignment progress UX
- Video playback with score following (`video_player`)
- Measure-to-timestamp map (`AlignmentMap`)
- Lookup tables: `chroma_params.json`, `dtw_params.json`
