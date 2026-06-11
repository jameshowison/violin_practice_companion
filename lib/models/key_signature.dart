/// Key-signature accidental defaults. Given a key's `fifths` count
/// (positive = sharps, negative = flats; the MusicXML `<fifths>` value) and a
/// step letter (A–G), returns the alter (−1/0/+1) the key signature implies for
/// that letter when no explicit accidental is written. Used by the measure
/// editor: moving a note diatonically resets its accidental to the key default.
class KeySignature {
  // Order in which sharps / flats are added as `fifths` grows.
  static const _sharpOrder = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
  static const _flatOrder = ['B', 'E', 'A', 'D', 'G', 'C', 'F'];

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
}
