import 'note_event.dart';

/// Key-signature accidental defaults. Given a key's `fifths` count
/// (positive = sharps, negative = flats; the MusicXML `<fifths>` value) and a
/// step letter (A–G), returns the alter (−1/0/+1) the key signature implies for
/// that letter when no explicit accidental is written. Used by the measure
/// editor: moving a note diatonically resets its accidental to the key default.
class KeySignature {
  // Order in which sharps / flats are added as `fifths` grows.
  static const _sharpOrder = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
  static const _flatOrder = ['B', 'E', 'A', 'D', 'G', 'C', 'F'];

  /// The letters a key signature of [fifths] carries, in the order they are
  /// written: `3` → F C G, `-2` → B E. Empty for C.
  static List<String> accidentalSteps(int fifths) => fifths >= 0
      ? _sharpOrder.take(fifths.clamp(0, 7)).toList()
      : _flatOrder.take((-fifths).clamp(0, 7)).toList();

  /// Default alter for [step] under a key of [fifths] sharps (+) / flats (−).
  static int defaultAlter(int fifths, String step) {
    if (fifths > 0) {
      final n = fifths.clamp(0, 7);
      if (_sharpOrder.take(n).contains(step)) return 1;
    } else if (fifths < 0) {
      final n = (-fifths).clamp(0, 7);
      if (_flatOrder.take(n).contains(step)) return -1;
    }
    return 0;
  }

  /// [note] as [rekeyBar] reads it; null for a rest or an unreadable pitch.
  static KeyedNote? keyedOf(NoteEvent note) {
    if (note.isRest) return null;
    final m = RegExp(r'^([A-G])([#b]?)(-?\d+)$').firstMatch(note.pitch);
    if (m == null) return null;
    return (
      step: m.group(1)!,
      octave: int.parse(m.group(3)!),
      alter: m.group(2) == '#' ? 1 : (m.group(2) == 'b' ? -1 : 0),
      written: note.displayAccidental != null,
      tieStop: note.tieStop,
    );
  }

  /// [keyed] as a [rekeyBar] carry that the change doesn't touch: the bar
  /// before a key change's last note, which a tie into it continues.
  static KeyCarry? unchangedCarry(KeyedNote? keyed) => keyed == null
      ? null
      : (
          step: keyed.step,
          octave: keyed.octave,
          oldAlter: keyed.alter,
          newAlter: keyed.alter,
        );

  /// How a key signature of [fifths] reads at a glance: `0`, `2♯`, `3♭`.
  static String label(int fifths) =>
      fifths == 0 ? '0' : '${fifths.abs()}${fifths > 0 ? '♯' : '♭'}';

  /// The accidentals a key of [fifths] carries, as written: `F♯ C♯`. Empty
  /// for C.
  static String signs(int fifths) => accidentalSteps(fifths)
      .map((s) => '$s${fifths > 0 ? '♯' : '♭'}')
      .join(' ');

  /// The alters the pitched notes of ONE bar take when the key in force moves
  /// from [from] to [to]: the re-spelling a key-signature fix implies.
  ///
  /// MusicXML stores sounding pitch, so a scan that misread D major as G
  /// major wrote every C as C♮. Relabelling the key alone would leave those
  /// notes sounding (and drawn) wrong; this moves them with it. A note moves
  /// only when it was following the key:
  ///
  ///  * it has no written accidental ([KeyedNote.written]),
  ///  * no earlier note on its line (step and octave) in the bar wrote one —
  ///    a written accidental holds to the barline, and
  ///  * its alter is [from]'s for its letter (anything else was already
  ///    inconsistent with the key, and guessing would make it worse).
  ///
  /// A tie continuing a note ([KeyedNote.tieStop]) keeps the pitch of the
  /// note it continues, which is how a tie across a key change keeps the old
  /// key's pitch: pass the bar before's last note as [carryIn], unchanged.
  ///
  /// [notes] holds null for anything unpitched (a rest), which comes back
  /// null. The second value is the bar's last pitched note, as [carryIn] for
  /// the next bar.
  static (List<int?>, KeyCarry?) rekeyBar(
      List<KeyedNote?> notes, int from, int to,
      {KeyCarry? carryIn}) {
    final written = <String>{};
    var prev = carryIn;
    final out = <int?>[];
    for (final n in notes) {
      if (n == null) {
        out.add(null);
        continue;
      }
      final line = '${n.step}${n.octave}';
      int alter = n.alter;
      if (n.written) {
        written.add(line);
      } else if (n.tieStop &&
          prev != null &&
          prev.step == n.step &&
          prev.octave == n.octave &&
          prev.oldAlter == n.alter) {
        alter = prev.newAlter;
      } else if (!written.contains(line) &&
          n.alter == defaultAlter(from, n.step)) {
        alter = defaultAlter(to, n.step);
      }
      out.add(alter);
      prev = (step: n.step, octave: n.octave, oldAlter: n.alter, newAlter: alter);
    }
    return (out, prev);
  }
}

/// A pitched note as [KeySignature.rekeyBar] sees it: its letter, octave and
/// sounding alter, whether it has a written accidental, and whether it
/// continues a tie.
typedef KeyedNote = ({
  String step,
  int octave,
  int alter,
  bool written,
  bool tieStop,
});

/// The last pitched note of a bar, before and after a re-spelling — what a
/// tie into the next bar continues.
typedef KeyCarry = ({String step, int octave, int oldAlter, int newAlter});
