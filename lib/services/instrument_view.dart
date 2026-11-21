import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:xml/xml.dart';

import '../models/instrument_profile.dart';

/// How a piece's source score is shown for one instrument: the instrument
/// layer of docs/family/layers.md.
///
/// A source already written in the instrument's clef is shown exactly as it
/// is. A source in another clef (a violin part, for a viola) is rewritten
/// into the instrument's clef and moved by whole octaves to sit in its range,
/// chosen per piece. Only whole octaves, so a recording's alignment (by
/// chroma, which ignores the octave) still holds.
///
/// The view is never saved. An edit made on it goes back to the source
/// through [toSource], so the shared score is never overwritten with one
/// instrument's transcription.
class InstrumentView {
  final InstrumentProfile profile;

  /// The view is the source moved by this many octaves.
  final int octaves;

  /// Whether the clefs are rewritten to [InstrumentProfile.clef].
  final bool reclef;

  const InstrumentView._(this.profile, this.octaves, this.reclef);

  /// The source as it stands, for [profile].
  const InstrumentView.identity(this.profile)
      : octaves = 0,
        reclef = false;

  /// The view of [sourceXml] for [profile]: identity when the source opens in
  /// the profile's clef (or has no clef), otherwise the profile's clef at the
  /// octave that puts the most notes inside its range. Among octaves that do
  /// equally well, the one whose median note is nearest the middle of the
  /// range: a tune that fits either way is played across the instrument, not
  /// all on its top string. Then the smaller move.
  factory InstrumentView.of(InstrumentProfile profile, String sourceXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(sourceXml);
    } catch (_) {
      return InstrumentView.identity(profile);
    }
    final clef = _firstClef(doc);
    if (clef == null || clef == profile.clef) {
      return InstrumentView.identity(profile);
    }
    final midis = [
      for (final p in doc.findAllElements('pitch'))
        if (_midiOf(p) case final m?) m,
    ];
    if (midis.isEmpty) return InstrumentView._(profile, 0, true);
    final median = ([...midis]..sort())[midis.length ~/ 2];
    final middle = (profile.lowestMidi + profile.highestMidi) / 2;
    int inRange(int k) => midis
        .where((m) =>
            m + 12 * k >= profile.lowestMidi &&
            m + 12 * k <= profile.highestMidi)
        .length;
    double offCentre(int k) => (median + 12 * k - middle).abs();
    var best = 0;
    for (final k in const [-1, 1, -2, 2]) {
      final better = inRange(k) > inRange(best) ||
          (inRange(k) == inRange(best) && offCentre(k) < offCentre(best));
      if (better) best = k;
    }
    return InstrumentView._(profile, best, true);
  }

  bool get isIdentity => octaves == 0 && !reclef;

  /// [sourceXml] as this instrument reads it. Identical (the same string)
  /// for an identity view.
  String apply(String sourceXml) {
    if (isIdentity) return sourceXml;
    final doc = XmlDocument.parse(sourceXml);
    if (octaves != 0) {
      for (final name in const ['octave', 'display-octave']) {
        for (final e in doc.findAllElements(name)) {
          final o = int.tryParse(e.innerText.trim());
          if (o != null) e.innerText = '${o + octaves}';
        }
      }
    }
    if (reclef) {
      for (final c in doc.findAllElements('clef')) {
        c.getElement('sign')?.innerText = profile.clef.sign;
        c.getElement('line')?.innerText = '${profile.clef.line}';
        c.getElement('clef-octave-change')?.remove();
      }
    }
    return doc.toXmlString();
  }

  /// [notes] edited on this view, as they belong in the source. The same
  /// list for an identity view.
  List<NoteEvent> toSource(List<NoteEvent> notes) =>
      octaves == 0 ? notes : [for (final n in notes) _shift(n, -octaves)];

  static NoteEvent _shift(NoteEvent n, int by) {
    if (n.isRest) return n;
    final m = RegExp(r'^(.*?)(-?\d+)$').firstMatch(n.pitch);
    final pitch = m == null
        ? n.pitch
        : '${m.group(1)}${int.parse(m.group(2)!) + by}';
    return n.copyWith(
      pitch: pitch,
      octave: n.octave + by,
      midiNumber: n.midiNumber + 12 * by,
    );
  }

  static Clef? _firstClef(XmlDocument doc) {
    final c = doc.findAllElements('clef').firstOrNull;
    if (c == null) return null;
    final sign = c.getElement('sign')?.innerText.trim();
    final line = int.tryParse(c.getElement('line')?.innerText.trim() ?? '');
    if (sign == null) return null;
    // A G clef without a line is on the second, a C clef on the third: the
    // MusicXML defaults.
    return (
      sign: sign,
      line: line ?? switch (sign) { 'G' => 2, 'C' => 3, 'F' => 4, _ => 0 },
    );
  }

  static int? _midiOf(XmlElement pitch) {
    const steps = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
    final step = steps[pitch.getElement('step')?.innerText.trim()];
    final octave = int.tryParse(pitch.getElement('octave')?.innerText.trim() ?? '');
    if (step == null || octave == null) return null;
    final alter =
        double.tryParse(pitch.getElement('alter')?.innerText.trim() ?? '') ?? 0;
    return (octave + 1) * 12 + step + alter.round();
  }
}
