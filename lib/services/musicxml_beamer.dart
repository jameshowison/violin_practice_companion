import 'package:xml/xml.dart';

/// Writes the `<beam>` elements a measure needs when it has none.
///
/// Beaming is *derived*, not stored. Nothing in this app's model carries it:
/// [MusicXmlParser] doesn't read `<beam>` and [NoteEvent] has no field for it,
/// so a measure the editor rewrites comes back with every eighth separately
/// flagged. Keeping the old elements around wouldn't fix that — a beam belongs
/// to a *group*, so retyping one note invalidates its neighbours' beams and the
/// group has to be worked out again anyway. Working it out is therefore the
/// whole answer, and it fixes more than it was asked to: notes the user has just
/// added get beamed too, and so does a scan that arrived with no beaming at all.
///
/// **Only a measure with no beams is touched.** If the engraver said something,
/// it is respected; this fills silence, it doesn't second-guess. That keeps
/// MuseScore's and abcjs's own beaming byte-identical — they beam as they were
/// typed, which is more faithful than any rule — and it makes the pass
/// idempotent, since its own output trips the same gate next time.
///
/// See [_beamSpan] for the rule and the evidence behind it.
class MusicXmlBeamer {
  /// How far a beam group may run, in 32nd-note units. A run of beamable notes
  /// is broken wherever it crosses one of these boundaries.
  ///
  /// **A half note in simple meters, a dotted beat in compound ones.** Not one
  /// beat: engravers beam eighths across the half bar, and beaming per beat
  /// would turn a bar of Gossec's Gavotte from two groups of four into four
  /// pairs — legal, but visibly unlike every bar around it.
  ///
  /// Measured by stripping every `<beam>` from the bundled scores and the ABC
  /// goldens, rebeaming, and comparing whole *groups* — not merely which notes
  /// end up beamed, which is a much weaker test that any sane rule passes.
  ///
  /// Outside 3/4 this reproduces the scores almost exactly: **143 of 147
  /// measures**. The four misses are two over-long bars in
  /// `abc_10_allegretto.xml`, where the beat grid is meaningless anyway, and
  /// one bar of each Gavotte whose twelve sixteenths the engraver grouped by
  /// quarter rather than by half. A one-beat span scores 29/72 on the same 4/4
  /// material — that is the difference this constant exists to make.
  ///
  /// 3/4 is the honest gap: 53 of 90. The ABC-converted Minuets beam whole bars
  /// while the OMR reading of the same printed pages beams in halves, so no
  /// single span fits both, and a whole-bar span merely trades one for the
  /// other. The printed page is what a player looks at, so halves win. The gate
  /// above keeps the cost low — a bar only reaches this rule with no beaming to
  /// lose.
  ///
  /// (A two-tier span — halves for eighths, quarters for sixteenths, which is
  /// what the Gavotte bars above want — was tried and is a wash: it fixes
  /// `abc_17_gavotte.xml` and breaks `homr_17_gavotte.xml` by the same margin.
  /// The two engravings of that bar disagree with each other.)
  ///
  /// Deliberately *not* shared with `AbcExporter._beamUnits`, which answers a
  /// different question — where to put a space so a human reading ABC source
  /// can see the beats. Sharing them was the first thing tried here, and it is
  /// what produced the pairs-instead-of-fours above.
  static int _beamSpan(int beatsPerMeasure, int beatType) {
    final beat = 32 ~/ beatType;
    if (beatType == 8 && beatsPerMeasure % 3 == 0) return beat * 3;
    final bar = beat * beatsPerMeasure;
    return bar < 16 ? bar : 16;
  }

  /// Returns [musicXml] with a `<beam>` on every note that should carry one,
  /// or unchanged when every measure already states its beaming (or has nothing
  /// beamable). Unparseable input is returned as-is — this is a repair, not a
  /// validation step, and callers downstream report the parse failure.
  static String rebeam(String musicXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }

    final timeEl = doc.findAllElements('time').firstOrNull;
    final span = _beamSpan(
      _intOf(timeEl, 'beats') ?? 4,
      _intOf(timeEl, 'beat-type') ?? 4,
    );

    // `<divisions>` is stated in an `<attributes>` and holds until restated, so
    // it's carried across measures rather than read once.
    var divisions = 1;
    var changed = false;
    for (final measureEl in doc.findAllElements('measure')) {
      for (final attrEl in measureEl.findElements('attributes')) {
        divisions = _intOf(attrEl, 'divisions') ?? divisions;
      }
      if (measureEl.findAllElements('beam').isNotEmpty) continue;
      changed = _beamMeasure(measureEl, divisions, span) || changed;
    }
    return changed ? doc.toXmlString() : musicXml;
  }

  /// Beams one measure. Returns whether it wrote anything.
  static bool _beamMeasure(XmlElement measureEl, int divisions, int span) {
    // Every note in document order, with the beat it starts in and how many
    // beams its value calls for.
    final notes = <({XmlElement el, int beat, int flags})>[];
    var position = 0;
    for (final noteEl in measureEl.findElements('note')) {
      // A grace note steals its time from a neighbour rather than occupying
      // any, and a chord member shares the primary note's stem — neither
      // advances the beat, and neither takes a beam of its own.
      if (noteEl.findElements('grace').isNotEmpty) continue;
      final isChord = noteEl.findElements('chord').isNotEmpty;
      if (isChord) continue;

      final beamable = noteEl.findElements('rest').isEmpty;
      notes.add((
        el: noteEl,
        beat: position ~/ span,
        flags: beamable
            ? (_flags[noteEl.findElements('type').firstOrNull?.innerText.trim()] ?? 0)
            : 0,
      ));
      final duration =
          int.tryParse(noteEl.findElements('duration').firstOrNull?.innerText.trim() ?? '');
      position += duration == null ? 0 : (duration * 8 / divisions).round();
    }

    var wrote = false;
    // Maximal runs of adjacent beamable notes sharing a beat. A rest or a
    // quarter-or-longer note ends the run; so does crossing into the next beat.
    var start = 0;
    while (start < notes.length) {
      if (notes[start].flags == 0) {
        start++;
        continue;
      }
      var end = start + 1;
      while (end < notes.length &&
          notes[end].flags > 0 &&
          notes[end].beat == notes[start].beat) {
        end++;
      }
      if (end - start >= 2) {
        _beamGroup(notes.sublist(start, end));
        wrote = true;
      }
      start = end;
    }
    return wrote;
  }

  /// Writes the beams for one group of two or more notes.
  ///
  /// Each level is laid out independently, because a group need not be uniform:
  /// the dotted eighth + sixteenth that fiddle tunes are made of carries one
  /// beam across both notes and a second on the sixteenth alone. A level a
  /// single note reaches gets a hook rather than a `begin` with no `end` —
  /// pointing back toward the group unless the note opens it.
  static void _beamGroup(List<({XmlElement el, int beat, int flags})> group) {
    final maxFlags = group.map((n) => n.flags).reduce((a, b) => a > b ? a : b);
    for (var level = 1; level <= maxFlags; level++) {
      var i = 0;
      while (i < group.length) {
        if (group[i].flags < level) {
          i++;
          continue;
        }
        var j = i + 1;
        while (j < group.length && group[j].flags >= level) {
          j++;
        }
        if (j - i == 1) {
          _addBeam(group[i].el, level, i == 0 ? 'forward hook' : 'backward hook');
        } else {
          for (var k = i; k < j; k++) {
            _addBeam(group[k].el, level,
                k == i ? 'begin' : (k == j - 1 ? 'end' : 'continue'));
          }
        }
        i = j;
      }
    }
  }

  /// Appends `<beam number="$level">$state</beam>` where the MusicXML DTD wants
  /// it: after the note's own attributes, before `<notations>` and `<lyric>`.
  static void _addBeam(XmlElement noteEl, int level, String state) {
    final beam = XmlElement(
      XmlName('beam'),
      [XmlAttribute(XmlName('number'), '$level')],
      [XmlText(state)],
    );
    final at = noteEl.children.indexWhere((n) =>
        n is XmlElement &&
        (n.name.local == 'notations' || n.name.local == 'lyric'));
    if (at == -1) {
      noteEl.children.add(beam);
    } else {
      noteEl.children.insert(at, beam);
    }
  }

  static int? _intOf(XmlElement? parent, String tag) =>
      int.tryParse(parent?.findElements(tag).firstOrNull?.innerText.trim() ?? '');

  /// How many beams each note value carries. Anything longer than an eighth —
  /// and anything unlisted — takes none.
  static const _flags = {
    'eighth': 1,
    '16th': 2,
    '32nd': 3,
    '64th': 4,
    '128th': 5,
  };
}
