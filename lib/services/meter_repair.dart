import 'package:xml/xml.dart';

import '../models/parsed_piece.dart';
import 'measure_xml_editor.dart';

/// Puts a scanned score's time signatures where its bars say they are.
///
/// The recogniser reads note values far better than it reads time-signature
/// digits. On one page of a Christmas medley that moves 3/4 → 4/4 → 2/4 →
/// 4/4 → 3/4 → 4/4 it read the bars nearly perfectly but wrote a 4/4 as
/// "3/4", a 2/4 as "4/4", missed a 3/4 altogether, and — on the uncropped
/// photo — found no time signature at all. The bars themselves are the better
/// witness: seven bars of three quarters in a row are in 3/4, whatever digit
/// the recogniser thought it saw.
///
/// So the meter is re-derived from bar lengths, stretch by stretch:
///  * A bar whose length is 2, 3 or 4 quarters is evidence for 2/4, 3/4 or
///    4/4 — or for the meter already in force, when that has the same length
///    (6/8 and 3/4 bars are equally long; 2/2 and 4/4 too), so a correct
///    6/8 or 2/2 is never relabelled.
///  * Any other length is OMR damage (two bars merged, a note lost, a false
///    triplet) and is no evidence either way. It stays as it is, for the
///    measure editor to flag.
///  * Where the recogniser put a `<time>`, the meter changes there: to what it
///    read if that fits the bar, otherwise to what the bar's length says —
///    unless the bar is a pickup into what it read (shorter, the next bar
///    full): Barbara Allen opens with a 3-beat pickup under its 3/2. That
///    leaves a genuine one-bar 2/4 misread as 4/4 flagged rather than fixed;
///    a wrong relabel would print time signatures that aren't there.
///  * Where it put none, the meter changes only after [minRun] bars in a row
///    agree on a new length (damaged bars between them don't break the run).
///    One odd bar is a reading error, not a change of meter.
///  * An empty bar under a `<time>` (a multi-measure rest) can't judge the
///    digits: the meter of the bars after it (two in a row) stands instead.
///    The recogniser opened a medley's rests with "7/4" before its 3/4 bars.
///  * The first meter found is the opening meter, written into the first bar,
///    so a pickup (or a scan cropped below the opening system) still starts
///    the piece in the right meter.
///
/// No notes are touched — this only relabels, as the time-signature card does.
/// A score whose `<time>`s already agree with its bars comes back unchanged.
class MeterRepair {
  /// Bars in a row of one new length before an unmarked meter change is
  /// believed. Two would let a single bar split 2 + 2 by a phantom barline
  /// turn a 4/4 tune into 2/4 for a moment.
  static const minRun = 3;

  /// Bar lengths, in 32nd-note units, that are evidence for a meter.
  static const _byLength = {
    16: Meter(2, 4),
    24: Meter(3, 4),
    32: Meter(4, 4),
  };

  /// [musicXml] with its time signatures repaired; unchanged if nothing
  /// needed it or it doesn't parse.
  static String repair(String musicXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }
    final changes = <String, Meter?>{};
    for (final part in doc.findAllElements('part')) {
      final plan = planFor(part.findElements('measure').toList());
      changes.addAll(plan);
    }
    if (changes.isEmpty) return musicXml;

    var xml = musicXml;
    for (final e in changes.entries) {
      // The editor addresses bars by number; an OMR "12a" can't be reached.
      final number = int.tryParse(e.key);
      if (number == null) continue;
      final m = e.value;
      xml = m == null
          ? MeasureXmlEditor.removeTimeChange(xml, number)
          : MeasureXmlEditor.setTimeChange(xml, number,
              beats: m.beats, beatType: m.beatType);
    }
    return xml;
  }

  /// The edits [measures] need, keyed by measure number: a meter to write, or
  /// null to remove a `<time>` that restates the meter already in force.
  /// Empty when the score's `<time>`s already fit.
  static Map<String, Meter?> planFor(List<XmlElement> measures) {
    final bars = _readBars(measures);
    if (bars.isEmpty) return const {};

    final want = <int, Meter>{};
    Meter? current;
    for (var i = 0; i < bars.length; i++) {
      final bar = bars[i];
      final candidate = _candidate(bar.units, current);
      if (bar.written != null) {
        final written = bar.written!;
        // The digits stand when the bar can't judge them (damaged), when it
        // agrees, or when it is a pickup INTO the written meter: shorter, with
        // the next bar the full length. A song's opening anacrusis, or a new
        // section's, carries the time signature of the bars after it.
        final pickup = bar.units != null &&
            bar.units! < written.units &&
            _nextLength(bars, i) == written.units;
        // An empty bar (a multi-measure rest) can't vouch for its digits at
        // all: the bars that follow it say what they were.
        final meter = bar.units == 0
            ? _followingMeter(bars, i, written) ?? written
            : candidate == null || written.units == bar.units || pickup
                ? written
                : candidate;
        if (current == null || meter != current) want[i] = meter;
        current = meter;
        continue;
      }
      if (candidate == null) continue;
      if (current != null && candidate.units == current.units) continue;
      if (_runLength(bars, i, candidate.units) <
          (current == null ? 2 : minRun)) {
        continue;
      }
      want[i] = candidate;
      current = candidate;
    }
    if (want.isEmpty) return const {};

    // The first meter found opens the piece.
    final first = want.keys.reduce((a, b) => a < b ? a : b);
    if (first != 0) want[0] = want.remove(first)!;

    final plan = <String, Meter?>{};
    for (var i = 0; i < bars.length; i++) {
      final written = bars[i].written;
      final wanted = want[i];
      if (wanted != null) {
        if (written != wanted) plan[bars[i].number] = wanted;
      } else if (written != null && i > 0) {
        plan[bars[i].number] = null; // restates the meter in force
      }
    }
    return plan;
  }

  /// The length of the first bar after [i] that has one.
  static int? _nextLength(List<_Bar> bars, int i) {
    for (var k = i + 1; k < bars.length; k++) {
      final u = bars[k].units;
      if (u != null && u > 0) return u;
    }
    return null;
  }

  /// The meter of the bars after the empty bar [i], when at least two in a
  /// row agree on it and it isn't [written]'s length; otherwise null.
  static Meter? _followingMeter(List<_Bar> bars, int i, Meter written) {
    for (var k = i + 1; k < bars.length; k++) {
      if (bars[k].written != null) return null;
      final u = bars[k].units;
      if (u == null || u == 0) continue;
      final m = _candidate(u, written);
      if (m == null || m == written) return null;
      return _runLength(bars, k, u) >= 2 ? m : null;
    }
    return null;
  }

  /// The meter a bar of [units] is evidence for, or null if none.
  static Meter? _candidate(int? units, Meter? current) {
    if (units == null || units == 0) return null;
    if (current != null && current.units == units) return current;
    return _byLength[units];
  }

  /// Bars from [from] on that agree on [units], skipping damaged ones, until
  /// one that says otherwise.
  static int _runLength(List<_Bar> bars, int from, int units) {
    var n = 0;
    for (var k = from; k < bars.length; k++) {
      final u = bars[k].units;
      if (k > from && bars[k].written != null) break;
      if (u == units) {
        n++;
      } else if (u != null && _byLength.containsKey(u)) {
        break;
      }
    }
    return n;
  }

  /// Each measure's number, length and written `<time>`.
  static List<_Bar> _readBars(List<XmlElement> measures) {
    var divisions = 1;
    final bars = <_Bar>[];
    for (final m in measures) {
      Meter? written;
      for (final a in m.findElements('attributes')) {
        divisions = _int(a, 'divisions') ?? divisions;
        final t = a.findElements('time').firstOrNull;
        final beats = _int(t, 'beats');
        final beatType = _int(t, 'beat-type');
        if (beats != null && beatType != null && beats > 0 && beatType > 0) {
          written ??= Meter(beats, beatType);
        }
      }
      bars.add(_Bar(m.getAttribute('number') ?? '${bars.length + 1}',
          _units(m, divisions), written));
    }
    return bars;
  }

  /// A measure's length in 32nd-note units: the furthest its voices reach.
  /// Null when it doesn't come to a whole number of 32nds (a tuplet read
  /// wrongly), which is damage, not a length.
  static int? _units(XmlElement measure, int divisions) {
    var pos = 0, end = 0, last = 0;
    for (final el in measure.childElements) {
      final d = _int(el, 'duration') ?? 0;
      switch (el.name.local) {
        case 'note':
          if (el.findElements('grace').isNotEmpty) continue;
          if (el.findElements('chord').isNotEmpty) {
            end = end > pos - last + d ? end : pos - last + d;
            continue;
          }
          last = d;
          pos += d;
        case 'backup':
          pos -= d;
        case 'forward':
          pos += d;
        default:
          continue;
      }
      if (pos > end) end = pos;
    }
    final units = end * 8 / divisions;
    return units == units.roundToDouble() ? units.round() : null;
  }

  static int? _int(XmlElement? parent, String tag) => int.tryParse(
      parent?.findElements(tag).firstOrNull?.innerText.trim() ?? '');
}

class _Bar {
  final String number;
  final int? units;
  final Meter? written;
  const _Bar(this.number, this.units, this.written);
}
