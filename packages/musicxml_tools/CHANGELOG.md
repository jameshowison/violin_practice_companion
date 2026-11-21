## 0.2.0

- `Clef` and `Transpose`, and `ParsedPiece.openingClef` /
  `ParsedPiece.openingTranspose`: the first part's opening `<clef>` (sign,
  line, octave change) and `<transpose>` (chromatic, diatonic, octave change;
  sounding minus written), null when the score has none. Also as
  `MusicXmlParser.openingClefOf` / `openingTransposeOf` on a parsed document.
  Read and exposed only: nothing transposes the notes.

## 0.1.0

- First version, moved out of Stringlings: the note model (`NoteEvent`,
  `ParsedPiece`, `DurationStep`, `KeySignature`), `MusicXmlParser`,
  `MeasureXmlEditor`, the OMR repairs, the chord/lyric/fingering injectors,
  the preamble generator, `AbcExporter` and `JianpuDigits`.
