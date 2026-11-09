import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/widgets/count_in_label.dart';

void main() {
  group('countInDotOffset', () {
    const xs = [0.0, 10.0, 20.0, 30.0]; // three numbers and the trailing ..

    test('touches down on every number exactly on its beat', () {
      for (var b = 0; b < 3; b++) {
        final p = countInDotOffset(b.toDouble(), 3, xs);
        expect(p.x, xs[b]);
        expect(p.lift, 0);
      }
    });

    test('lands on the trailing dots at the first note', () {
      final p = countInDotOffset(3, 3, xs);
      expect(p.x, 30);
      expect(p.lift, 0);
    });

    test('the last hop - the breath - rises highest', () {
      final hop = countInDotOffset(0.5, 3, xs).lift;
      final breath = countInDotOffset(2.5, 3, xs).lift;
      expect(breath, greaterThan(hop * 1.5));
    });

    test('a short last beat lands early', () {
      // 2.5 beats: the last hop spans 2..2.5.
      expect(countInDotOffset(2.25, 2.5, xs).x, closeTo(25, 1e-9));
      expect(countInDotOffset(2.5, 2.5, xs).x, 30);
    });

    test('lead rests after the last number stretch the breath to the note',
        () {
      // Happy Farmer: count 1 2 3 to the pickup barline (beat 3), then a
      // hidden eighth rest — the D is heard at 3.5.
      expect(countInDotOffset(2.75, 3.5, xs).x, closeTo(25, 1e-9));
      expect(countInDotOffset(3.0, 3.5, xs).lift, greaterThan(0),
          reason: 'still in the air at the barline');
      expect(countInDotOffset(3.5, 3.5, xs), (x: 30.0, lift: 0.0));
    });

    test('rests on the first number before the count (an intro)', () {
      expect(countInDotOffset(-2, 3, xs), (x: 0.0, lift: 0.0));
    });
  });

  testWidgets('draws the numbers with a dot, and the intro without', (t) async {
    Widget host(double? intro) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: CountInLabel(
                tick: (
                  labels: const [1, 2, 3],
                  index: 1,
                  startMeasure: 1,
                  totalBeats: 3,
                  introProgress: intro,
                ),
                height: 34,
                beatPosition: () => 1.5,
              ),
            ),
          ),
        );
    await t.pumpWidget(host(null));
    await t.pump(const Duration(milliseconds: 20));
    expect(find.textContaining('2'), findsOneWidget);
    await t.pumpWidget(host(0.4));
    expect(find.text('Intro…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
