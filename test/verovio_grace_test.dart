import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';

/// Grace notes must not take a positional noteIndex: the parser skips them,
/// so an anchor for one shifts every later note in its bar one place early.
/// They are told apart by the toolkit's `getElementAttr`, since the native
/// Verovio build does not honour `svgAdditionalAttribute`.
void main() {
  test('a grace note is recognised from its element attributes', () {
    // Verovio 6.2's answer for Gossec bar 2's F#5 grace note.
    expect(
      VerovioEngraver.isGraceAttr('{"dur":"8","dur.ppq":"0","grace":"unacc",'
          '"oct":"5","pname":"f","stem.dir":"up","stem.mod":"1slash"}'),
      isTrue,
    );
  });

  test('an ordinary note is not', () {
    expect(
      VerovioEngraver.isGraceAttr(
          '{"dur":"4","oct":"5","pname":"g","stem.dir":"down"}'),
      isFalse,
    );
  });

  test('junk is not', () {
    expect(VerovioEngraver.isGraceAttr(''), isFalse);
    expect(VerovioEngraver.isGraceAttr('[]'), isFalse);
  });
}
