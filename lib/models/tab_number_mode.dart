/// What the tab view draws on each of the 4 string lines.
enum TabNumberMode {
  /// The violin fingering we already compute (0–4, incl. the L/H suffix),
  /// rendered verbatim. Default — this is a violin practice app.
  violinFingering,

  /// True mandolin tablature: the fret number (semitones above the open string).
  mandolinFret,
}
