/// The soprano recorder's fingering chart (docs/family/windlings-app.md, step
/// W2): which holes are closed for each written note, the group the colour
/// lane shows, and the words the side panel says when the fingers change.
///
/// Pure data and pure functions, no Flutter: the hole diagram
/// (`widgets/hole_diagram.dart`) and the side panel
/// (`widgets/recorder_fingering_panel.dart`) draw what this says.
library;

/// One hole, or the thumb hole at the back.
///
/// [half] is the thumb "pinched" (half-holed) for the upper octave, or ONE
/// of the two little holes of the double holes 6 and 7 covered, for the
/// semitone below (C♯4, D♯4, G♯4).
enum HoleState { open, half, closed }

/// The group the colour lane shows (approach.md §2.3: "you changed register
/// here", which is where beginners fail).
enum FingeringGroup {
  /// Thumb and left hand only: G4, A4, B4, C5.
  leftHand,

  /// Thumb on, and the right hand down too: the low notes.
  bothHands,

  /// The thumb off or half-holed: the second octave, over the break.
  thumbOff,
}

/// Which holes are covered for one note.
class HoleFingering {
  /// The thumb hole at the back (hole 0).
  final HoleState thumb;

  /// Holes 1 to 7, top to bottom: 1–3 the left hand, 4–7 the right. Only 6
  /// and 7 (the double holes) are ever [HoleState.half].
  final List<HoleState> holes;

  const HoleFingering(this.thumb, this.holes) : assert(holes.length == 7);

  /// From a compact pattern: the thumb then holes 1–7, `x` closed, `o` open,
  /// `h` half — `'x xxx oooo'` is G. Spaces are ignored.
  factory HoleFingering.parse(String pattern) {
    final s = pattern.replaceAll(' ', '');
    assert(s.length == 8, pattern);
    HoleState at(int i) => switch (s[i]) {
          'x' => HoleState.closed,
          'h' => HoleState.half,
          _ => HoleState.open,
        };
    return HoleFingering(at(0), [for (var i = 1; i < 8; i++) at(i)]);
  }

  /// The state of hole [i], 0 being the thumb.
  HoleState hole(int i) => i == 0 ? thumb : holes[i - 1];

  /// The group: thumb not fully down → [FingeringGroup.thumbOff]; any right
  /// hand hole covered → [FingeringGroup.bothHands]; else left hand only.
  FingeringGroup get group {
    if (thumb != HoleState.closed) return FingeringGroup.thumbOff;
    for (var i = 3; i < 7; i++) {
      if (holes[i] != HoleState.open) return FingeringGroup.bothHands;
    }
    return FingeringGroup.leftHand;
  }

  /// Back to the [HoleFingering.parse] pattern, for tests and debugging.
  String get pattern {
    String c(HoleState h) => switch (h) {
          HoleState.closed => 'x',
          HoleState.half => 'h',
          HoleState.open => 'o',
        };
    return '${c(thumb)} ${holes.take(3).map(c).join()} '
        '${holes.skip(3).map(c).join()}';
  }

  @override
  bool operator ==(Object other) =>
      other is HoleFingering &&
      other.thumb == thumb &&
      _listEq(other.holes, holes);

  @override
  int get hashCode => Object.hash(thumb, Object.hashAll(holes));

  @override
  String toString() => 'HoleFingering($pattern)';
}

bool _listEq(List<HoleState> a, List<HoleState> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One note of the chart: its usual fingering and any alternates.
class ChartEntry {
  final HoleFingering fingering;
  final List<HoleFingering> alternates;

  /// False where the public charts it was checked against disagree, or the
  /// note needs something the diagram can't show (the bell end stopped).
  /// [note] says which.
  final bool verified;
  final String? note;

  const ChartEntry(this.fingering,
      {this.alternates = const [], this.verified = true, this.note});

  FingeringGroup get group => fingering.group;
}

/// A fingering chart keyed on WRITTEN MIDI pitch — the notes
/// `parsedPieceProvider` carries for a transposing instrument.
class HoleFingeringChart {
  final String name;
  final Map<int, ChartEntry> entries;

  const HoleFingeringChart(this.name, this.entries);

  ChartEntry? operator [](int writtenMidi) => entries[writtenMidi];
  HoleFingering? fingeringFor(int writtenMidi) =>
      entries[writtenMidi]?.fingering;

  /// Soprano (descant) recorder, baroque ("English") fingering, written C4
  /// (60) to D6 (86).
  ///
  /// Checked on 2026-11-21 against two public charts, which agree on every
  /// note from C4 to A5:
  /// - Dolmetsch Online, "Baroque/English Fingerings for the Recorder in Text
  ///   Format" (dolmetsch.com/textfingeringchart.htm), recorder in C;
  /// - Wikipedia, "Recorder (musical instrument)", the English/baroque
  ///   fingering table (C-tuned column).
  /// Where they differ the entry follows Dolmetsch, keeps the other as an
  /// alternate, and is marked `verified: false`: B♭5, C♯6 and D6.
  static final HoleFingeringChart sopranoBaroque =
      HoleFingeringChart('Soprano recorder, baroque fingering', {
    // ── low octave: thumb down ──
    60: ChartEntry(HoleFingering.parse('x xxx xxxx')), // C4
    61: ChartEntry(HoleFingering.parse('x xxx xxxh')), // C♯4: half of 7
    62: ChartEntry(HoleFingering.parse('x xxx xxxo')), // D4
    63: ChartEntry(HoleFingering.parse('x xxx xxho')), // D♯4: half of 6
    64: ChartEntry(HoleFingering.parse('x xxx xxoo')), // E4
    65: ChartEntry(HoleFingering.parse('x xxx xoxx')), // F4: the forked F
    66: ChartEntry(HoleFingering.parse('x xxx oxxo')), // F♯4
    67: ChartEntry(HoleFingering.parse('x xxx oooo')), // G4
    68: ChartEntry(HoleFingering.parse('x xxo xxho'), // G♯4
        alternates: [HoleFingering.parse('x xxo xxxo')]),
    69: ChartEntry(HoleFingering.parse('x xxo oooo')), // A4
    70: ChartEntry(HoleFingering.parse('x xox xooo')), // B♭4
    71: ChartEntry(HoleFingering.parse('x xoo oooo'), // B4
        alternates: [HoleFingering.parse('x oxx oooo')]),
    72: ChartEntry(HoleFingering.parse('x oxo oooo')), // C5
    // ── over the break: thumb off, then half-holed ──
    73: ChartEntry(HoleFingering.parse('o xxo oooo')), // C♯5
    74: ChartEntry(HoleFingering.parse('o oxo oooo'), // D5
        alternates: [HoleFingering.parse('o xxx xxxx')]),
    75: ChartEntry(HoleFingering.parse('o oxx xxxo')), // D♯5
    76: ChartEntry(HoleFingering.parse('h xxx xxoo')), // E5
    77: ChartEntry(HoleFingering.parse('h xxx xoxo')), // F5
    78: ChartEntry(HoleFingering.parse('h xxx oxoo')), // F♯5
    79: ChartEntry(HoleFingering.parse('h xxx oooo')), // G5
    80: ChartEntry(HoleFingering.parse('h xxo xooo')), // G♯5
    81: ChartEntry(HoleFingering.parse('h xxo oooo')), // A5
    // UNVERIFIED: Dolmetsch has right 2–3 down; Wikipedia right 1–3.
    82: ChartEntry(HoleFingering.parse('h xxo oxxo'), // B♭5
        alternates: [HoleFingering.parse('h xxo xxxo')],
        verified: false,
        note: 'charts differ'),
    83: ChartEntry(HoleFingering.parse('h xxo xxoo')), // B5
    84: ChartEntry(HoleFingering.parse('h xoo xxoo')), // C6
    // UNVERIFIED: both charts stop the bell end (knee or a key) for C♯6, and
    // they differ on hole 7.
    85: ChartEntry(HoleFingering.parse('h xox xoxo'), // C♯6
        alternates: [HoleFingering.parse('h xox xoxx')],
        verified: false,
        note: 'close the bell end'),
    // UNVERIFIED: Wikipedia's table reads hole 7 down here too.
    86: ChartEntry(HoleFingering.parse('h xox xoxo'), // D6
        alternates: [HoleFingering.parse('h xox xoxx')],
        verified: false,
        note: 'charts differ'),
  });
}

/// What a hole is called in the side panel's instructions: the thumb, then
/// each hand's fingers counted from the top — hole 4 is "right 1".
String holeName(int i) => i == 0
    ? 'thumb'
    : i <= 3
        ? 'left $i'
        : 'right ${i - 3}';

/// What changes between [from] and [to], as the panel says it: one line per
/// kind of move, holes in order, thumb first.
///
/// - "Put down left 2, right 1" — holes covered fully that weren't;
/// - "Lift thumb, left 1" — holes opened fully;
/// - "Half-hole thumb" / "Half-cover right 3" — the pinched thumb, or one of
///   a double hole's pair.
///
/// Null [from] (the first note): "Start with …" naming every covered hole.
/// No change: an empty list.
List<String> fingeringChangeLines(HoleFingering? from, HoleFingering to) {
  if (from == null) {
    final down = <String>[
      for (var i = 0; i < 8; i++)
        if (to.hole(i) == HoleState.closed) holeName(i)
        else if (to.hole(i) == HoleState.half) 'half ${holeName(i)}',
    ];
    return [down.isEmpty ? 'Start with nothing down' : 'Start with ${down.join(', ')}'];
  }
  final putDown = <String>[], lift = <String>[], half = <String>[];
  for (var i = 0; i < 8; i++) {
    final a = from.hole(i), b = to.hole(i);
    if (a == b) continue;
    switch (b) {
      case HoleState.closed:
        putDown.add(holeName(i));
      case HoleState.open:
        lift.add(holeName(i));
      case HoleState.half:
        half.add(holeName(i));
    }
  }
  return [
    if (putDown.isNotEmpty) 'Put down ${putDown.join(', ')}',
    if (lift.isNotEmpty) 'Lift ${lift.join(', ')}',
    if (half.isNotEmpty)
      half.first == 'thumb'
          ? 'Half-hole ${half.join(', ')}'
          : 'Half-cover ${half.join(', ')}',
  ];
}

/// The holes that differ between [from] and [to], by index (0 = thumb), for
/// the diagram's highlight rings.
Set<int> changedHoles(HoleFingering? from, HoleFingering to) => from == null
    ? const {}
    : {
        for (var i = 0; i < 8; i++)
          if (from.hole(i) != to.hole(i)) i
      };

/// The register word under the note's letter: "low" for the first octave
/// (written C4–B4), "high" from C5 up — the mockup's "high C", "high D".
String registerWord(int writtenMidi) => writtenMidi < 72 ? 'low' : 'high';
