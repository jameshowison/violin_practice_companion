/// The winds' fingering charts: the soprano recorder's
/// (docs/family/windlings-app.md, step W2) and the keyless Irish flute's
/// (docs/plan.md §7.5). Which holes are closed for each written note, the
/// group the colour lane shows, and the words the side panel says when the
/// fingers change.
///
/// Pure data and pure functions, no Flutter: the hole diagram
/// (`widgets/hole_diagram.dart`) and the side panel
/// (`widgets/recorder_fingering_panel.dart`) draw what this says.
library;

/// One hole, or the thumb hole at the back.
///
/// On the recorder, [half] is the thumb "pinched" (half-holed) for the upper
/// octave, or ONE of the two little holes of the double holes 6 and 7
/// covered, for the semitone below (C♯4, D♯4, G♯4). On the keyless flute it
/// is a finger half over its hole, for a semitone it has no key for.
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

  /// The same fingers blown harder: a flute's second and third octaves,
  /// which no hole tells apart from the first ([ChartEntry.overblown]).
  overblown,
}

/// Which holes are covered for one note: a recorder's (the thumb and seven
/// holes) or a keyless flute's (six holes, no thumb hole).
class HoleFingering {
  /// The thumb hole at the back (hole 0); null for an instrument without one
  /// (the flute).
  final HoleState? thumb;

  /// The finger holes, top to bottom: 1–3 the left hand, the rest the right.
  /// Seven on the recorder, where only 6 and 7 (the double holes) are ever
  /// [HoleState.half]; six on the flute.
  final List<HoleState> holes;

  const HoleFingering(this.thumb, this.holes)
      : assert(thumb == null ? holes.length == 6 : holes.length == 7);

  /// From a compact pattern, `x` closed, `o` open, `h` half, spaces ignored:
  /// eight symbols are the thumb then holes 1–7 (`'x xxx oooo'` is a
  /// recorder's G), six are a flute's holes 1–6 (`'xxx ooo'` its G).
  factory HoleFingering.parse(String pattern) {
    final s = pattern.replaceAll(' ', '');
    assert(s.length == 8 || s.length == 6, pattern);
    HoleState at(int i) => switch (s[i]) {
          'x' => HoleState.closed,
          'h' => HoleState.half,
          _ => HoleState.open,
        };
    final hasThumb = s.length == 8;
    return HoleFingering(hasThumb ? at(0) : null,
        [for (var i = hasThumb ? 1 : 0; i < s.length; i++) at(i)]);
  }

  /// Whether there is a thumb hole (hole 0).
  bool get hasThumb => thumb != null;

  /// One more than the last hole's index: holes are `0..holeCount`, 0 the
  /// thumb, which reads as always open where there is none.
  int get holeCount => holes.length + 1;

  /// The state of hole [i], 0 being the thumb (open when there is none, so
  /// it never changes and is never named).
  HoleState hole(int i) => i == 0 ? (thumb ?? HoleState.open) : holes[i - 1];

  /// The group, by the holes alone: thumb not fully down →
  /// [FingeringGroup.thumbOff]; any right hand hole covered →
  /// [FingeringGroup.bothHands]; else left hand only. (A flute's octave is
  /// not in its holes: [ChartEntry.group].)
  FingeringGroup get group {
    if (hasThumb && thumb != HoleState.closed) return FingeringGroup.thumbOff;
    for (var i = 3; i < holes.length; i++) {
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
    final hands = '${holes.take(3).map(c).join()} '
        '${holes.skip(3).map(c).join()}';
    return hasThumb ? '${c(thumb!)} $hands' : hands;
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

  /// Blown into a higher octave with the fingers of a lower one (the
  /// flute's): its group is then [FingeringGroup.overblown].
  final bool overblown;

  const ChartEntry(this.fingering,
      {this.alternates = const [],
      this.verified = true,
      this.note,
      this.overblown = false});

  FingeringGroup get group =>
      overblown ? FingeringGroup.overblown : fingering.group;
}

/// A fingering chart keyed on WRITTEN MIDI pitch — the notes
/// `parsedPieceProvider` carries for a transposing instrument.
class HoleFingeringChart {
  final String name;
  final Map<int, ChartEntry> entries;

  /// The first written note called "high" under the panel's letter
  /// ([registerWord]): C5 on the recorder, D5 on the flute.
  final int highFrom;

  const HoleFingeringChart(this.name, this.entries, {this.highFrom = 72});

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

  /// The keyless six-hole Irish flute in D (the "simple-system" flute most
  /// session players start on; docs/plan.md §7.5), written and sounding D4
  /// (62) to D6 (86). No thumb hole; the second octave is the first's
  /// fingers blown harder ([ChartEntry.overblown]), and D6 is the third.
  ///
  /// Checked on 2026-11-23 against Margaret Fleck's keyless flute charts:
  /// the complete one (mfleck.cs.illinois.edu/flute-fingerings.html) and
  /// the simple one (flute-fingerings-simple.html, "fairly standard
  /// fingerings"). They agree on every natural note of the D scale and on
  /// D♯ and F. The entry is the simple chart's; the complete chart's other
  /// fingerings are alternates. A keyless flute has no key for the other
  /// semitones, so they are a half-hole or a cross-fingering whose tuning
  /// depends on the flute, and the two charts differ on them. Those are
  /// `verified: false`. The chart wants checking with a real player.
  static final HoleFingeringChart irishFluteKeyless = HoleFingeringChart(
    'Irish flute in D, keyless',
    highFrom: 74,
    {
      ..._fluteOctave(0),
      ..._fluteOctave(12),
      // D6, the third octave: the complete chart's "esp flutes" fingering,
      // the simple chart's only one; its "esp fifes" is the alternate.
      86: ChartEntry(HoleFingering.parse('oxx ooo'),
          alternates: [HoleFingering.parse('oxx xxx')], overblown: true),
    },
  );

  /// One octave of the flute, D to C♯, [octave] semitones above D4.
  static Map<int, ChartEntry> _fluteOctave(int octave) {
    final up = octave > 0;
    ChartEntry e(String p,
            {List<String> alt = const [], bool verified = true, String? note}) =>
        ChartEntry(HoleFingering.parse(p),
            alternates: [for (final a in alt) HoleFingering.parse(a)],
            verified: verified,
            note: note,
            overblown: up);
    return {
      62 + octave: e('xxx xxx'), // D
      63 + octave: e('xxx xxh', note: 'half-hole'), // D♯: half of right 3
      64 + octave: e('xxx xxo'), // E
      65 + octave: e('xxx xho', alt: ['xxx xox'], note: 'half-hole'), // F
      66 + octave: e('xxx xoo'), // F♯
      67 + octave: e('xxx ooo'), // G
      // UNVERIFIED: the simple chart cross-fingers G♯, the complete one
      // half-holes left 3 first.
      68 + octave: e(up ? 'xxo xoo' : 'xxo xxx',
          alt: ['xxh ooo'], verified: false, note: 'charts differ'),
      69 + octave: e('xxo ooo'), // A
      // UNVERIFIED: B♭ likewise, cross-fingered or left 2 half-holed.
      70 + octave: e(up ? 'xox ooo' : 'xox xxx',
          alt: ['xho ooo'], verified: false, note: 'charts differ'),
      71 + octave: e('xoo ooo'), // B
      // C natural, the one the tunes in G need, cross-fingered. The charts
      // also give it with two fingers down below, or left 1 half-holed.
      // UNVERIFIED: which one a player is taught first varies.
      72 + octave: e('oxx ooo',
          alt: ['oxo xxx', 'hoo ooo'], verified: false, note: 'cross-fingered'),
      73 + octave: e('ooo ooo'), // C♯: everything off
    };
  }
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
      for (var i = 0; i < to.holeCount; i++)
        if (to.hole(i) == HoleState.closed) holeName(i)
        else if (to.hole(i) == HoleState.half) 'half ${holeName(i)}',
    ];
    return [down.isEmpty ? 'Start with nothing down' : 'Start with ${down.join(', ')}'];
  }
  final putDown = <String>[], lift = <String>[], half = <String>[];
  for (var i = 0; i < to.holeCount; i++) {
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
        for (var i = 0; i < to.holeCount; i++)
          if (from.hole(i) != to.hole(i)) i
      };

/// The register word under the note's letter: "low" below [highFrom]
/// ([HoleFingeringChart.highFrom]: written C5 on the recorder), "high" from
/// there up — the mockup's "high C", "high D".
String registerWord(int writtenMidi, {int highFrom = 72}) =>
    writtenMidi < highFrom ? 'low' : 'high';

/// What the breath does between [from] and [to] on an overblown instrument
/// (the flute), where the same fingers play two octaves: "Blow harder" up
/// into a higher octave, "Blow softer" back down, else null. The holes say
/// nothing about it, so without this an octave leap reads "Same fingers".
String? breathChangeLine(ChartEntry? from, ChartEntry to) {
  if (from == null) return null;
  if (!from.overblown && to.overblown) return 'Blow harder';
  if (from.overblown && !to.overblown) return 'Blow softer';
  return null;
}
