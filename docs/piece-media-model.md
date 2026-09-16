# One model for everything that plays a piece

A piece can be played by the synthesized score, by a bundled backing track, by
a file the user imported, or by a demo they recorded. Before this change those
were three unrelated code paths plus an `else` branch. They are now one list of
`PieceMedia`.

## What it replaced

| | bundled asset | recorded demo | the score itself | imported file |
|---|---|---|---|---|
| located by | `_audioSyncFolders` map | absolute paths in prefs | — | did not exist |
| anchors in | `AudioSyncAnchorsStore` | `TeacherRecordingStore` | — | — |
| played by | `AudioSyncPlaybackService` | `TeacherRecordingPlaybackService` | `PlaybackService` | — |
| tray | `PlayAlongControls` | `TeacherDemoControls` | `PlaybackControls` | — |
| turned on by | `playAlongModeProvider` | `teacherDemoModeProvider` | neither being true | — |

The two playback services were the same class: the anchor sort, the
degenerate-segment filter, both interpolators, both bracket searches, the
seek-target rule and all four `PlaybackServiceBase` overrides were identical
character for character. The second one's header said so outright, and gave a
reasonable reason at the time — *"kept as its own class … so neither feature
risks the other"*. They never diverged, and the split cost real things:

- The absolute-path bug existed **only** on the recording side, because only the
  asset side had a notion of "where the bytes live" that survived the app
  moving. One model, one answer.
- The highlight settings were gated on the presence of a bundled asset folder
  and wired only into the Play Along service — so for a piece whose only audio
  was a recording, opening the gate would not have helped.
- The two mode booleans had to be kept mutually exclusive by hand at every call
  site.
- Only the staff view followed the audio. The jianpu view, the fingering view
  and the section minimap were handed the metronome service regardless, because
  the audio clock reached the staff through a `highlightNotifierOverride` patch
  rather than through the service everyone reads.

## The model

`lib/models/piece_media.dart`

```dart
PieceMedia(id, label, kind, alignmentKey, audio, analysis, video, avOffsetMs,
           contentStartSeconds, contentEndSeconds)
```

- **`MediaRef`** — an asset key, or a path **relative to the documents
  directory**, resolved against the current one on every read. iOS does not
  guarantee container-path stability, so an absolute path is a path that can
  outlive what it names. This is the same conclusion `PieceStorage` reached for
  MusicXML.
- **`kind`** — `synthesized` | `bundled` | `imported` | `recorded`. Affects
  presentation and what may be deleted; **not** how anything is played.
- **`analysis`** — what DTW reads. Usually the same file as `audio`; for bundled
  tracks always `melody.wav` whichever mix is playing, because it is the
  closest match to the score's own notes. Null means "plays, but the score
  won't follow".
- **`alignmentKey`** — deliberately not the media id. A piece's `mix`, `melody`
  and `chords` are three mixes of one session and share one timeline, so they
  share one cached alignment and the user waits for it once.
- **`contentStartSeconds` / `contentEndSeconds`** — where the tune itself sits
  inside `analysis`, when the user has said. Both null by default, which means
  "work it out from the audio" and is the only possibility for a bundled track.
  Here rather than on `MediaAlignment` because they are an INPUT to DTW and a
  realign clears the alignment row. Edited from the picker row's scissors
  button; see [audio-sync-next-steps.md](audio-sync-next-steps.md) item 3.

`PieceMedia.synthesized` is a const entry with no files and no alignment. It is
in the enum rather than being the absence of media so the picker can offer it
as one choice among the rest.

## Where things live

| | |
|---|---|
| `MediaCatalog` | assembles the list: synthesized, then bundled, then user media |
| `PieceMediaStore` | user media per piece (`pieceMedia.<pieceId>`) |
| `MediaAlignmentStore` | anchors by alignment key (`mediaAlignment.<key>`) |
| `MediaMigration` | brings the two legacy prefs blobs forward, idempotently |
| `MediaPlaybackService` | plays anything with a file behind it |
| `MediaImporter` | picks a file and copies it in |
| `AudioDecoder` | compressed audio → mono PCM, per platform |
| `MediaControls` | the one tray: picker + transport |

The synthesized score is **not** in `MediaPlaybackService`. It is played by the
soundfont engine in `PlaybackService`, which triggers real MIDI notes and has
no file, no anchors and nothing to align. Merging it in would mean a class that
is two unrelated things joined by an `if` — which is the shape this change
exists to undo. The unification is at the model, the picker and the tray; the
two engines stay two engines.

## Migration

Neither legacy blob carries a schema version and there is no hook to bump one,
so migration is inferred from the keys and runs on first read:

- `audioSyncAnchors.<pieceId>` → `mediaAlignment.bundled:<folder>`, so an
  already-aligned piece does not re-align.
- `teacherRecording.<pieceId>` → one `PieceMedia` with relative refs, plus its
  alignment row. The absolute path is relativized by finding the
  `teacher_recordings/` segment, which works on iOS (`.../Documents/`) and
  Android (`.../app_flutter/`) alike.

Both skip when their destination already exists, so after the first run they
cost two in-memory prefs lookups. **Nothing is deleted** — the legacy keys stay
where they are, so rolling back to an older build still finds its data. Files
are not moved either: a migrated recording keeps living under
`teacher_recordings/` while new ones are written to `media/<pieceId>/<mediaId>/`.
Moving a user's only copy of a recording to fix a tidiness problem is a bad
trade.

## The decoder

Alignment needs PCM, and `package:wav` reads WAV and nothing else. That was
invisible while the app supplied all its own audio — it is why bundled folders
ship a `melody.wav` beside their mp3s, and why the teacher-demo capture records
a silent video plus a separate WAV. It stops being invisible the moment a user
picks an m4a off their phone: the file plays perfectly and cannot be aligned,
so the same action produces a working medium or a half-working one depending on
a container format nobody chose.

So: `AudioDecoder`, behind the usual conditional-import split — `AVAssetReader`
on iOS/macOS, `MediaExtractor` + `MediaCodec` on Android, `decodeAudioData` on
web. WAV short-circuits to pure Dart on every platform, which keeps the
alignment regression tests running headless and avoids a pointless round trip.

Decoding is whole-file: a five-minute 48 kHz recording is ~57 MB of
`Float64List`. Fine for a demo of one tune, not for an album side. The samples
are dropped as soon as chroma extraction has run.

Its on-device behaviour on real compressed audio is **not yet confirmed** — see
item 4 of [audio-sync-next-steps.md](audio-sync-next-steps.md).

## Adding a bundled track

Unchanged, and still two edits: a line in `PieceRepository._audioSyncFolders`
tying the piece id to a folder name, and the folder in `pubspec.yaml`'s asset
list. `MediaCatalog.bundledMediaFor` derives the three media from the folder
name; nothing is stored.
