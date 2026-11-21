import '../models/note_event.dart';

/// A note's Jianpu (numbered notation) digit: the scale degree 1–7 (0 for a
/// rest), how many octave dots above (+) or below (−), and whether it is a
/// raised degree (an accidental between scale notes).
typedef JianpuDigit = ({int number, int octaveDots, bool? sharp});

/// Jianpu digits from the key table (`jianpu_key_map.json`), which the caller
/// loads and passes in.
class JianpuDigits {
  final Map<String, dynamic> _keys;

  JianpuDigits(Map<String, dynamic> keyMap)
      : _keys = keyMap['keys'] as Map<String, dynamic>;

  /// Whether the table has the key with [keyFifths] sharps (− for flats).
  bool covers(int keyFifths) => _keys.containsKey(keyFifths.toString());

  /// [note]'s digit in the key with [keyFifths], or null when the table
  /// doesn't have that key. A rest is 0 with no dots; `sharp` is null on a
  /// scale note.
  JianpuDigit? digitOf(NoteEvent note, int keyFifths) {
    final keyEntry = _keys[keyFifths.toString()] as Map<String, dynamic>?;
    if (keyEntry == null) return null;
    if (note.isRest) return (number: 0, octaveDots: 0, sharp: null);

    final scale = (keyEntry['scale'] as List).cast<int>();
    final pc = note.midiNumber % 12;
    final noteOctave = (note.midiNumber ~/ 12) - 1;

    int jianpuNum;
    bool? sharp;
    final scaleIdx = scale.indexOf(pc);
    if (scaleIdx >= 0) {
      jianpuNum = scaleIdx + 1;
      sharp = null;
    } else {
      // Accidental: find the nearest lower scale degree
      int nearest = 0;
      for (int i = scale.length - 1; i >= 0; i--) {
        if (scale[i] < pc || (scale[i] > pc && scale[i] - pc > 6)) {
          nearest = i;
          break;
        }
      }
      jianpuNum = nearest + 1;
      sharp = true;
    }
    return (
      number: jianpuNum,
      octaveDots: noteOctave - _referenceOctave,
      sharp: sharp,
    );
  }

  // Middle C = MIDI 60, octave 4. The reference octave is 4 for every key the
  // table has.
  static const _referenceOctave = 4;
}
