import 'package:xml/xml.dart';

/// Removes the triplets a scan invented, and keeps the ones it read.
///
/// The recogniser takes a number printed over a group of notes for a tuplet
/// mark, and in a student's music that number is usually a fingering: across
/// the dev library's scans, five triplets were false (a "3", a "4" or an open
/// string "o" above the notes) and five were real (a minuet's three,
/// Salt Creek's hammer-on triplets). So none can be trusted on sight, and
/// dropping them all would break the real ones.
///
/// The bar decides. A triplet that makes its bar add up to the meter is kept;
/// one whose removal makes the bar add up is dropped; a bar that adds up
/// neither way has some other damage, and is left for the measure editor to
/// flag (its triplet toggle is the fix for whichever way this guessed wrong).
/// On the dev library this got nine of the ten bars it could judge right; the
/// tenth, a real triplet in a bar where two other notes were also misread,
/// happened to add up without it.
///
/// Run after `MeterRepair`: the judgement is only as good as the meter.
class TupletRepair {
  /// [musicXml] with its false tuplets made plain notes; unchanged if there
  /// were none, or it doesn't parse.
  static String repair(String musicXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }
    // The opening meter is the first <time> in the document, as the parser
    // reads it; 4/4 without one.
    final opening = doc.findAllElements('time').firstOrNull;
    var changed = false;
    for (final part in doc.findAllElements('part')) {
      var divisions = 1;
      var barUnits = _barUnits(opening) ?? 32;
      for (final m in part.findElements('measure')) {
        for (final a in m.findElements('attributes')) {
          divisions = _int(a, 'divisions') ?? divisions;
          barUnits = _barUnits(a.findElements('time').firstOrNull) ?? barUnits;
        }
        if (_judge(m, barUnits) == _Verdict.drop) {
          changed = _drop(m, divisions) || changed;
        }
      }
    }
    return changed ? doc.toXmlString() : musicXml;
  }

  static _Verdict _judge(XmlElement measure, int barUnits) {
    var withT = 0.0, without = 0.0;
    var any = false;
    for (final n in _timed(measure)) {
      final nominal = _nominal(n);
      if (nominal == null) return _Verdict.leave;
      final tm = n.findElements('time-modification').firstOrNull;
      without += nominal;
      if (tm == null) {
        withT += nominal;
        continue;
      }
      final actual = _int(tm, 'actual-notes'), normal = _int(tm, 'normal-notes');
      if (actual == null || normal == null || actual < 1) return _Verdict.leave;
      any = true;
      withT += nominal * normal / actual;
    }
    if (!any) return _Verdict.leave;
    bool fits(double u) => (u - barUnits).abs() < 1e-6;
    if (fits(withT)) return _Verdict.keep;
    if (fits(without)) return _Verdict.drop;
    return _Verdict.leave;
  }

  /// Makes every tuplet note in [measure] a plain one. False (and nothing
  /// changed) if a plain duration wouldn't be a whole number of [divisions].
  static bool _drop(XmlElement measure, int divisions) {
    final notes = [
      for (final n in measure.findElements('note'))
        if (n.findElements('time-modification').isNotEmpty) n,
    ];
    final durations = <int>[];
    for (final n in notes) {
      final d = _nominal(n)! * divisions / 8;
      if (d != d.roundToDouble() || d < 1) return false;
      durations.add(d.round());
    }
    for (var i = 0; i < notes.length; i++) {
      final n = notes[i];
      n.findElements('time-modification').toList().forEach((e) => e.remove());
      final dur = n.findElements('duration').firstOrNull;
      if (dur != null) dur.innerText = '${durations[i]}';
      for (final notations in n.findElements('notations').toList()) {
        notations.findElements('tuplet').toList().forEach((e) => e.remove());
        if (notations.childElements.isEmpty) notations.remove();
      }
    }
    return true;
  }

  /// The notes that take time: not grace notes, not chord members.
  static Iterable<XmlElement> _timed(XmlElement measure) =>
      measure.findElements('note').where((n) =>
          n.findElements('grace').isEmpty && n.findElements('chord').isEmpty);

  /// A note's written length in 32nd-note units, from its `<type>` and dots;
  /// null for a type this can't size.
  static double? _nominal(XmlElement note) {
    final type = note.findElements('type').firstOrNull?.innerText.trim();
    final base = switch (type) {
      'whole' => 32.0,
      'half' => 16.0,
      'quarter' => 8.0,
      'eighth' => 4.0,
      '16th' => 2.0,
      '32nd' => 1.0,
      _ => null,
    };
    if (base == null) {
      // A whole-bar rest is often written without a type.
      return null;
    }
    var value = base, add = base;
    for (var d = note.findElements('dot').length; d > 0; d--) {
      add /= 2;
      value += add;
    }
    return value;
  }

  static int? _barUnits(XmlElement? time) {
    final beats = _int(time, 'beats'), beatType = _int(time, 'beat-type');
    if (beats == null || beatType == null || beatType < 1) return null;
    return beats * 32 ~/ beatType;
  }

  static int? _int(XmlElement? parent, String tag) => int.tryParse(
      parent?.findElements(tag).firstOrNull?.innerText.trim() ?? '');
}

enum _Verdict { keep, drop, leave }
