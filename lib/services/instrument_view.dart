import 'package:musicxml_tools/musicxml_tools.dart' hide Clef;
import 'package:xml/xml.dart';

import '../models/instrument_profile.dart';

/// A transposition as written music needs it: how many letter names
/// ([steps]) and how many semitones. A fifth down is (-4, -7); an octave up
/// is (7, 12).
typedef Interval = ({int steps, int semitones});

/// How a piece's source score is shown for one instrument: the instrument
/// layer of docs/family/layers.md.
///
/// A source already written in the instrument's clef is shown exactly as it
/// is. A source in another clef (a violin part, for a viola) is rewritten
/// into the instrument's clef and transcribed: by the profile's
/// [InstrumentProfile.transcription] (none, or a fifth down for a viola that
/// keeps the violin's finger patterns), then by whole octaves to sit in the
/// instrument's range, chosen per piece.
///
/// The view is never saved. An edit made on it goes back to the source
/// through [toSource] and [keyToSource], so the shared score is never
/// overwritten with one instrument's transcription.
class InstrumentView {
  final InstrumentProfile profile;

  /// The view is the source moved by this interval.
  final Interval interval;

  /// Whether the clefs are rewritten to [InstrumentProfile.clef].
  final bool reclef;

  const InstrumentView._(this.profile, this.interval, this.reclef);

  /// The source as it stands, for [profile].
  const InstrumentView.identity(this.profile)
      : interval = (steps: 0, semitones: 0),
        reclef = false;

  /// The view of [sourceXml] for [profile]: identity when the source opens in
  /// the profile's clef (or has no clef). Otherwise the profile's clef, its
  /// transcription, and the octave that puts the most notes inside its range;
  /// among octaves that do equally well, the one whose median note is nearest
  /// the middle of the range (a tune that fits either way is played across
  /// the instrument, not all on its top string), then the smaller move.
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
    final base = switch (profile.transcription) {
      Transcription.none => (steps: 0, semitones: 0),
      Transcription.fifthDown => (steps: -4, semitones: -7),
    };
    final midis = [
      for (final p in doc.findAllElements('pitch'))
        if (_midiOf(p) case final m?) m + base.semitones,
    ];
    Interval at(int k) =>
        (steps: base.steps + 7 * k, semitones: base.semitones + 12 * k);
    if (midis.isEmpty) return InstrumentView._(profile, at(0), true);
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
    return InstrumentView._(profile, at(best), true);
  }

  bool get isIdentity => interval.semitones == 0 && !reclef;

  /// Whole octaves only: a recording's alignment, by chroma, still holds.
  bool get keepsPitchClasses => interval.semitones % 12 == 0;

  /// [sourceXml] as this instrument reads it. Identical (the same string)
  /// for an identity view.
  String apply(String sourceXml) {
    if (isIdentity) return sourceXml;
    final doc = XmlDocument.parse(sourceXml);
    _transpose(doc, interval);
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
  List<NoteEvent> toSource(List<NoteEvent> notes) => interval.semitones == 0
      ? notes
      : [for (final n in notes) _shiftNote(n, _inverse)];

  /// A key signature (in fifths) chosen on this view, as the source states
  /// it.
  int keyToSource(int fifths) => fifths + _fifthsDelta(_inverse);

  Interval get _inverse =>
      (steps: -interval.steps, semitones: -interval.semitones);

  // ── Transposition ──────────────────────────────────────────────────────

  static const _letters = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
  static const _natural = [0, 2, 4, 5, 7, 9, 11];

  /// [step]/[alter]/[octave] moved by [by], spelled by letter name: a
  /// diatonic transposition, so D major's F♯ comes out as G major's B.
  static ({String step, int alter, int octave}) _move(
      String step, int alter, int octave, Interval by) {
    final idx = _letters.indexOf(step);
    final diatonic = octave * 7 + idx + by.steps;
    final newOctave = (diatonic / 7).floor();
    final newIdx = diatonic % 7;
    final midi = (octave + 1) * 12 + _natural[idx] + alter + by.semitones;
    final newAlter = midi - ((newOctave + 1) * 12 + _natural[newIdx]);
    return (step: _letters[newIdx], alter: newAlter, octave: newOctave);
  }

  /// How a key signature's count of fifths changes under [by].
  static int _fifthsDelta(Interval by) {
    final d = ((by.semitones * 7) % 12 + 12) % 12;
    return d > 6 ? d - 12 : d;
  }

  static const _accidentalOf = {
    -2: 'flat-flat',
    -1: 'flat',
    0: 'natural',
    1: 'sharp',
    2: 'double-sharp',
  };

  static void _transpose(XmlDocument doc, Interval by) {
    if (by.semitones == 0) return;
    for (final p in doc.findAllElements('pitch')) {
      final step = p.getElement('step')?.innerText.trim();
      final octave =
          int.tryParse(p.getElement('octave')?.innerText.trim() ?? '');
      if (step == null || octave == null || !_letters.contains(step)) continue;
      final alterEl = p.getElement('alter');
      final alter = double.tryParse(alterEl?.innerText.trim() ?? '')?.round() ?? 0;
      final to = _move(step, alter, octave, by);
      p.getElement('step')!.innerText = to.step;
      p.getElement('octave')!.innerText = '${to.octave}';
      if (to.alter == 0) {
        alterEl?.remove();
      } else if (alterEl != null) {
        alterEl.innerText = '${to.alter}';
      } else {
        // <alter> sits between <step> and <octave>.
        p.children.insert(
            p.children.indexOf(p.getElement('octave')!),
            XmlElement(XmlName('alter'), [], [XmlText('${to.alter}')]));
      }
      // A drawn sign follows the new spelling.
      final note = p.parent;
      if (note is XmlElement) {
        final acc = note.getElement('accidental');
        if (acc != null && _accidentalOf[to.alter] != null) {
          acc.innerText = _accidentalOf[to.alter]!;
        }
      }
    }
    // A rest's placement moves with the music.
    for (final rest in doc.findAllElements('rest')) {
      final s = rest.getElement('display-step');
      final o = rest.getElement('display-octave');
      final octave = int.tryParse(o?.innerText.trim() ?? '');
      if (s == null || o == null || octave == null) continue;
      final to = _move(s.innerText.trim(), 0, octave, by);
      s.innerText = to.step;
      o.innerText = '${to.octave}';
    }
    final delta = _fifthsDelta(by);
    if (delta != 0) {
      for (final f in doc.findAllElements('fifths')) {
        final v = int.tryParse(f.innerText.trim());
        if (v != null) f.innerText = '${v + delta}';
      }
    }
    // Chord symbols: the root and the bass, by letter name.
    for (final (stepName, alterName) in const [
      ('root-step', 'root-alter'),
      ('bass-step', 'bass-alter'),
    ]) {
      for (final s in doc.findAllElements(stepName)) {
        final parent = s.parent;
        if (parent is! XmlElement) continue;
        final alterEl = parent.getElement(alterName);
        final alter =
            double.tryParse(alterEl?.innerText.trim() ?? '')?.round() ?? 0;
        final to = _move(s.innerText.trim(), alter, 4, by);
        s.innerText = to.step;
        if (to.alter == 0) {
          alterEl?.remove();
        } else if (alterEl != null) {
          alterEl.innerText = '${to.alter}';
        } else {
          parent.children.insert(parent.children.indexOf(s) + 1,
              XmlElement(XmlName(alterName), [], [XmlText('${to.alter}')]));
        }
      }
    }
  }

  static NoteEvent _shiftNote(NoteEvent n, Interval by) {
    if (n.isRest) return n;
    final m = RegExp(r'^([A-G])([#b]?)(-?\d+)$').firstMatch(n.pitch);
    if (m == null) return n;
    final alter = switch (m.group(2)) { '#' => 1, 'b' => -1, _ => 0 };
    var to = _move(m.group(1)!, alter, int.parse(m.group(3)!), by);
    if (to.alter.abs() > 1) {
      // The note's pitch string spells one sharp or flat at most: respell a
      // double one enharmonically (B𝄪 as C♯), keeping the sounding pitch.
      to = _respell(to);
    }
    final pitch =
        '${to.step}${switch (to.alter) { 1 => '#', -1 => 'b', _ => '' }}${to.octave}';
    final shown = n.displayAccidental;
    return n.copyWith(
      pitch: pitch,
      octave: to.octave,
      midiNumber: n.midiNumber + by.semitones,
      displayAccidental:
          shown == null ? null : (_accidentalOf[to.alter] ?? shown),
    );
  }

  static ({String step, int alter, int octave}) _respell(
      ({String step, int alter, int octave}) p) {
    final midi = (p.octave + 1) * 12 + _natural[_letters.indexOf(p.step)] + p.alter;
    final pc = midi % 12;
    final octave = midi ~/ 12 - 1;
    final natural = _natural.indexOf(pc);
    if (natural >= 0) return (step: _letters[natural], alter: 0, octave: octave);
    final below = _natural.indexOf(pc - 1);
    return p.alter > 0
        ? (step: _letters[below], alter: 1, octave: octave)
        : (step: _letters[_natural.indexOf(pc + 1)], alter: -1, octave: octave);
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
    final step = pitch.getElement('step')?.innerText.trim();
    final octave = int.tryParse(pitch.getElement('octave')?.innerText.trim() ?? '');
    final idx = _letters.indexOf(step ?? '');
    if (idx < 0 || octave == null) return null;
    final alter =
        double.tryParse(pitch.getElement('alter')?.innerText.trim() ?? '') ?? 0;
    return (octave + 1) * 12 + _natural[idx] + alter.round();
  }
}
