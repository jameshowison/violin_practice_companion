import 'package:xml/xml.dart';

import '../models/key_signature.dart';

/// Rewrites MusicXML that leaves key-signature accidentals implicit so that
/// every `<pitch>` states its **sounding** pitch.
///
/// The app ingests MusicXML written to two incompatible conventions.
///
/// A conforming file states the sounding pitch: an F♯ under a one-sharp
/// signature carries `<alter>1</alter>` even though no sharp is drawn. That is
/// what MuseScore, the OMR output and this app's own measure editor produce
/// (see `edit_measure_screen.dart`, which resolves a note's alteration through
/// [KeySignature.defaultAlter] before writing it).
///
/// The bundled abcjs converter instead writes `<alter>` only where an
/// accidental is actually *drawn*, leaving the signature's sharps implicit — so
/// reading its `<alter>` literally turns every F♯ in Old Joe Clark into an F♮.
/// Verovio hides the problem, because it applies the key signature itself when
/// it engraves; only the sounding side (playback, fingerings, jianpu, tab) goes
/// wrong. This class is what makes the two agree, by resolving the drawing-led
/// file into a conforming one on the way in.
///
/// Neither convention can be detected from a single note, but it shows up
/// reliably across a piece: a drawing-led file only ever alters a pitch where it
/// also draws the sign, so an `<alter>` with **no** `<accidental>` beside it is
/// the fingerprint of a sounding-pitch file. Find one anywhere in the piece and
/// the file already says what it means; find none and the key signature has to
/// be applied.
///
/// (The tempting simpler test — "does any note restate the key signature?" —
/// looks equivalent and isn't. The Devil's Dream is written `BA^GB` in A major,
/// a redundant sharp on a note the signature already sharpens, which is enough
/// to make a drawing-led file look like a sounding-pitch one and would turn
/// every other F♯ and C♯ in the reel natural.)
class MusicXmlNormalizer {
  /// Returns [musicXml] with every pitch stating its sounding alteration.
  ///
  /// A file that already follows the sounding-pitch convention is returned
  /// **unchanged, character for character** — the fingerprint above is the gate,
  /// so nothing MuseScore or the OMR wrote is ever second-guessed. Unparseable
  /// input is likewise returned as-is; normalization is a repair, not a
  /// validation step, and callers downstream report the parse failure.
  ///
  /// Idempotent: the output is sounding-led, so a second pass is a no-op.
  static String toSoundingPitch(String musicXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }
    if (_isSoundingLed(doc)) return musicXml;

    final fifths = int.tryParse(doc
            .findAllElements('key')
            .firstOrNull
            ?.findElements('fifths')
            .firstOrNull
            ?.innerText
            .trim() ??
        '') ??
        0;

    for (final measureEl in doc.findAllElements('measure')) {
      // An accidental holds for the rest of its bar, on that step in that
      // octave only — a `^F` does not sharpen the F an octave up.
      final barAlters = <String, int>{};
      for (final noteEl in measureEl.findAllElements('note')) {
        final pitchEl = noteEl.findElements('pitch').firstOrNull;
        if (pitchEl == null) continue; // a rest
        final step = pitchEl.findElements('step').firstOrNull?.innerText.trim();
        if (step == null || step.isEmpty) continue;
        final octave = pitchEl.findElements('octave').firstOrNull?.innerText.trim();
        final key = '$step$octave';

        final drawn = _accidentalAlter[
            noteEl.findElements('accidental').firstOrNull?.innerText.trim()];
        final encoded = _encodedAlter(pitchEl);

        final int alter;
        if (drawn != null) {
          alter = drawn;
          barAlters[key] = drawn;
        } else if (encoded != 0) {
          // An explicit alteration is real data even undrawn — a ♭ in a sharp
          // key, say. Only a *missing* one is filled in from the context.
          alter = encoded;
        } else {
          alter = barAlters[key] ?? KeySignature.defaultAlter(fifths, step);
        }
        _setAlter(pitchEl, alter);
      }
    }
    return doc.toXmlString();
  }

  /// Returns [musicXml] with an `<accidental>` on every note that needs a
  /// sign drawn — the other half of the two conventions above.
  ///
  /// `<alter>` is pitch only; a visible sign is `<accidental>`, and Verovio
  /// draws none without it. The OMR wrote sounding pitch and no signs at all
  /// (fixed at the source in homr_flutter, after these scans were made), so a
  /// scanned A♯ in G major played and fingered as A♯ but was engraved as a
  /// plain A. A sign is needed where a note's alteration differs from what
  /// the key signature and the earlier notes in its bar imply, on that step,
  /// octave and staff; a note tied over from the bar before is never
  /// re-marked, and a sign already there is kept as it is.
  ///
  /// Runs on sounding-led input, so after [toSoundingPitch]. Returned
  /// unchanged, character for character, when no sign is missing.
  static String drawAccidentals(String musicXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }
    var changed = false;
    for (final part in doc.findAllElements('part')) {
      var fifths = 0;
      for (final measure in part.findElements('measure')) {
        final inBar = <String, int>{};
        for (final child in measure.childElements) {
          if (child.name.local == 'attributes') {
            final f = child
                .findElements('key')
                .firstOrNull
                ?.findElements('fifths')
                .firstOrNull
                ?.innerText;
            if (f != null) fifths = int.tryParse(f.trim()) ?? fifths;
            continue;
          }
          if (child.name.local != 'note') continue;
          final pitchEl = child.findElements('pitch').firstOrNull;
          if (pitchEl == null) continue;
          final step =
              pitchEl.findElements('step').firstOrNull?.innerText.trim();
          if (step == null || step.isEmpty) continue;
          final octave =
              pitchEl.findElements('octave').firstOrNull?.innerText.trim();
          final staff =
              child.findElements('staff').firstOrNull?.innerText.trim() ?? '1';
          final key = '$staff|$step$octave';
          final alter = _encodedAlter(pitchEl);
          if (child.findElements('accidental').isNotEmpty) {
            inBar[key] = alter;
            continue;
          }
          final tiedOver = child.findAllElements('tie').followedBy(
                  child.findAllElements('tied'))
              .any((t) => t.getAttribute('type') == 'stop');
          if (tiedOver) continue;
          if (alter == (inBar[key] ?? KeySignature.defaultAlter(fifths, step))) {
            continue;
          }
          final sign = _alterAccidental[alter];
          if (sign == null) continue;
          inBar[key] = alter;
          final at = child.children.indexWhere(
              (c) => c is XmlElement && _afterAccidental.contains(c.name.local));
          final el = XmlElement(XmlName.parts('accidental'), [], [XmlText(sign)]);
          if (at < 0) {
            child.children.add(el);
          } else {
            child.children.insert(at, el);
          }
          changed = true;
        }
      }
    }
    return changed ? doc.toXmlString() : musicXml;
  }

  /// Returns [musicXml] with every slur that is really a tie written as one:
  /// `<tie>` (held, not struck again) plus the `<tied>` arc.
  ///
  /// The OMR model has one token for both. homr's training data maps MusicXML
  /// `<tied>` and kern `[`/`]` to `slurStart`/`slurStop`, so a scan has no
  /// ties at all: Verovio draws the arc, but [MidiGenerator] strikes the held
  /// note again. A slur from one note to the very next in its voice, at the
  /// same pitch, is a tie, unless either note carries an articulation. A
  /// slur over repeated notes with tenuto or staccato marks is portato
  /// (Minuet 2, bar 2), and stays a slur.
  ///
  /// A file that already has a `<tie>` or `<tied>` anywhere can tell the two
  /// apart, so it is never second-guessed. Grace and chord notes are left
  /// alone. Returned unchanged, character for character, when nothing
  /// converts. Run it before [drawAccidentals], so a sharp tied over a
  /// barline is not marked again.
  static String slursToTies(String musicXml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(musicXml);
    } on XmlException {
      return musicXml;
    }
    if (doc.findAllElements('tie').isNotEmpty ||
        doc.findAllElements('tied').isNotEmpty) {
      return musicXml;
    }
    var changed = false;
    for (final part in doc.findAllElements('part')) {
      // Per staff and voice: the last note (or rest), and the note whose
      // slur is still open.
      final last = <String, XmlElement>{};
      final open = <String, XmlElement>{};
      for (final note in part.findAllElements('note')) {
        if (note.findElements('grace').isNotEmpty ||
            note.findElements('chord').isNotEmpty) {
          continue;
        }
        final key = '${note.findElements('staff').firstOrNull?.innerText.trim() ?? '1'}'
            '|${note.findElements('voice').firstOrNull?.innerText.trim() ?? '1'}';
        final prev = last[key];
        last[key] = note;
        final stop = _slur(note, 'stop');
        if (stop != null) {
          final start = open.remove(key);
          final startSlur = start == null ? null : _slur(start, 'start');
          if (start != null &&
              startSlur != null &&
              identical(start, prev) &&
              _samePitch(start, note) &&
              !_hasArticulation(start) &&
              !_hasArticulation(note)) {
            _tie(start, startSlur, 'start');
            _tie(note, stop, 'stop');
            changed = true;
          }
        }
        if (_slur(note, 'start') != null) open[key] = note;
      }
    }
    return changed ? doc.toXmlString() : musicXml;
  }

  static XmlElement? _slur(XmlElement note, String type) => note
      .findElements('notations')
      .expand((n) => n.findElements('slur'))
      .where((s) => s.getAttribute('type') == type)
      .firstOrNull;

  static bool _samePitch(XmlElement a, XmlElement b) {
    final pa = a.findElements('pitch').firstOrNull;
    final pb = b.findElements('pitch').firstOrNull;
    if (pa == null || pb == null) return false;
    String text(XmlElement p, String name) =>
        p.findElements(name).firstOrNull?.innerText.trim() ?? '';
    return text(pa, 'step') == text(pb, 'step') &&
        text(pa, 'octave') == text(pb, 'octave') &&
        _encodedAlter(pa) == _encodedAlter(pb);
  }

  static bool _hasArticulation(XmlElement note) => note
      .findElements('notations')
      .expand((n) => n.findElements('articulations'))
      .any((a) => a.childElements.isNotEmpty);

  /// Turns [slur] on [note] into a `<tied>` arc in place, and adds the
  /// sounding `<tie>` after `<duration>` (after a `<tie>` already there, so a
  /// note in the middle of a chain reads stop, then start).
  static void _tie(XmlElement note, XmlElement slur, String type) {
    slur.replace(XmlElement(XmlName.parts('tied'), [XmlAttribute(XmlName.parts('type'), type)]));
    final children = note.children;
    var at = children.lastIndexWhere(
        (c) => c is XmlElement && c.name.local == 'tie');
    if (at < 0) {
      at = children.indexWhere(
          (c) => c is XmlElement && c.name.local == 'duration');
    }
    children.insert(
        at + 1, XmlElement(XmlName.parts('tie'), [XmlAttribute(XmlName.parts('type'), type)]));
  }

  static const _alterAccidental = {
    0: 'natural',
    1: 'sharp',
    -1: 'flat',
    2: 'double-sharp',
    -2: 'flat-flat',
  };

  /// `<note>` children that follow `<accidental>` in the MusicXML schema.
  static const _afterAccidental = {
    'time-modification', 'stem', 'notehead', 'notehead-text', 'staff', 'beam',
    'notations', 'lyric', 'play', 'listen',
  };

  /// Whether any note alters a pitch without drawing the sign — see the class
  /// doc: one such note is enough to show the file states sounding pitch.
  static bool _isSoundingLed(XmlDocument doc) {
    for (final noteEl in doc.findAllElements('note')) {
      final pitchEl = noteEl.findElements('pitch').firstOrNull;
      if (pitchEl == null) continue;
      if (noteEl.findElements('accidental').isNotEmpty) continue;
      if (_encodedAlter(pitchEl) != 0) return true;
    }
    return false;
  }

  /// The `<alter>` this pitch carries, 0 when absent. Written as a decimal by
  /// some editors (`<alter>1.0</alter>`), and microtonal values round to the
  /// nearest semitone — the same reading [MusicXmlParser] does.
  static int _encodedAlter(XmlElement pitchEl) =>
      (double.tryParse(
                  pitchEl.findElements('alter').firstOrNull?.innerText.trim() ?? '') ??
              0.0)
          .round();

  /// Makes this pitch's `<alter>` say [alter], adding, updating or dropping the
  /// element as needed. A new one goes directly after `<step>`, where the
  /// MusicXML DTD requires it.
  static void _setAlter(XmlElement pitchEl, int alter) {
    final existing = pitchEl.findElements('alter').firstOrNull;
    if (alter == 0) {
      existing?.remove();
      return;
    }
    if (existing != null) {
      existing.innerText = '$alter';
      return;
    }
    final stepEl = pitchEl.findElements('step').first;
    pitchEl.children.insert(
      pitchEl.children.indexOf(stepEl) + 1,
      XmlElement(XmlName.parts('alter'), [], [XmlText('$alter')]),
    );
  }

  /// MusicXML `<accidental>` values that pin down an alteration. Unlisted ones
  /// (`quarter-sharp`, editorial variants) fall through to the encoded value
  /// rather than being rounded into a semitone the file never claimed.
  static const _accidentalAlter = {
    'natural': 0,
    'sharp': 1,
    'flat': -1,
    'double-sharp': 2,
    'sharp-sharp': 2,
    'double-flat': -2,
    'flat-flat': -2,
  };
}
