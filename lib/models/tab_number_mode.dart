/// What the tab view draws on each of the 4 string lines.
enum TabNumberMode {
  /// The violin fingering we already compute (0–4, incl. the L/H suffix),
  /// rendered verbatim. Default — this is a violin practice app.
  violinFingering,

  /// True mandolin tablature: the fret number (semitones above the open string).
  mandolinFret,
}

/// How the tab view assigns each note to a string when showing fret numbers.
enum TabFretStyle {
  /// Prefer the highest open string so frets stay low (≤6) — beginner-friendly
  /// (e.g. A4 = open A "0" rather than "7" on the D string). Default.
  openStrings,

  /// Put the fret on the same string the violin fingering uses, so the fret
  /// mirrors where you'd actually play it (may read as high as fret 7).
  matchFingering,
}
