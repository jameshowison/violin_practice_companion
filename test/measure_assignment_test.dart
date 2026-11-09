import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/verovio_engraver.dart';

void main() {
  // Happy Farmer's first system: the pickup's ink (its "Allegro giocoso" tempo
  // mark) runs past the barline at x=130 over bar 1's opening G at x≈155.
  const pickup =
      MeasureAnchor(index: 0, id: 'm0', rect: Rect.fromLTRB(60, 0, 205, 100));
  const bar1 =
      MeasureAnchor(index: 1, id: 'm1', rect: Rect.fromLTRB(130, 10, 420, 90));
  const measures = [pickup, bar1];
  Rect head(double x) => Rect.fromCenter(center: Offset(x, 50), width: 8, height: 6);

  test('a note under a spilling tempo mark belongs to the bar it starts in',
      () {
    expect(VerovioEngraver.measureIndexFor(head(155), measures), 1);
  });

  test('the pickup keeps its own note', () {
    expect(VerovioEngraver.measureIndexFor(head(90), measures), 0);
  });

  test('a note in one bar only is unaffected', () {
    expect(VerovioEngraver.measureIndexFor(head(300), measures), 1);
  });

  group('clipToNextMeasure', () {
    test('cuts a spill at the next bar on the same system', () {
      expect(VerovioEngraver.clipToNextMeasure(pickup.rect, bar1.rect),
          const Rect.fromLTRB(60, 0, 130, 100));
    });

    test('leaves the last bar of a system alone', () {
      const nextSystem = Rect.fromLTRB(20, 200, 300, 290);
      expect(VerovioEngraver.clipToNextMeasure(bar1.rect, nextSystem), bar1.rect);
      expect(VerovioEngraver.clipToNextMeasure(bar1.rect, null), bar1.rect);
    });

    test('leaves bars that do not overlap alone', () {
      const r = Rect.fromLTRB(0, 0, 100, 80);
      const next = Rect.fromLTRB(100, 0, 200, 80);
      expect(VerovioEngraver.clipToNextMeasure(r, next), r);
    });
  });
}
