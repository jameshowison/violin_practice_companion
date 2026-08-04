/// What number labels a note: the violin fingering, or the mandolin fret.
///
/// One preference, shared by the tab staff and the annotation view's fingering
/// channel, because it is a fact about the player rather than about a view — a
/// mandolinist reading these scores wants frets wherever numbers appear, and
/// having to set it per view would just be two places to forget.
enum NoteNumberMode {
  /// The violin fingering we already compute (0–4, incl. the L/H suffix),
  /// rendered verbatim. Default — this is a violin practice app.
  violinFingering,

  /// True mandolin tablature: the fret number (semitones above the open string).
  mandolinFret,
}

/// How a note is assigned to a string when showing fret numbers. Shared by the
/// same two views as [NoteNumberMode].
///
/// Both answers are pedagogically real, which is why this stays a choice rather
/// than a default: a beginner wants the low frets, and a player who has learned
/// to reach wants the fret where their hand already is.
enum FretStyle {
  /// Prefer the highest open string so frets stay low (≤6) — beginner-friendly
  /// (e.g. A4 = open A "0" rather than "7" on the D string). Default.
  openStrings,

  /// Put the fret on the same string the violin fingering uses, so the fret
  /// mirrors where you'd actually play it (may read as high as fret 7). In the
  /// fingering channel this also keeps every chip the colour it had in fingering
  /// mode, since the colour follows the string — only the digits change.
  matchFingering,
}
