import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/widgets/count_in_label.dart';

void main() {
  group('countInDotOffset', () {
    test('touches down on every number exactly on its beat', () {
      for (var b = 0; b < 3; b++) {
        expect(countInDotOffset(b.toDouble(), 3, 3), (x: b.toDouble(), lift: 0.0));
      }
    });

    test('covers the same distance in every beat', () {
      // x is the beat itself: a steady pulse is a steady speed.
      for (final b in [0.25, 0.5, 1.25, 1.9, 2.5]) {
        expect(countInDotOffset(b, 3, 3).x, b);
      }
    });

    test('lands one slot past the last number, on the first note', () {
      expect(countInDotOffset(3, 3, 3), (x: 3.0, lift: 0.0));
    });

    test('the last hop - the breath - rises highest', () {
      final hop = countInDotOffset(0.5, 3, 3).lift;
      final breath = countInDotOffset(2.5, 3, 3).lift;
      expect(breath, greaterThan(hop * 1.5));
    });

    test('a short last beat lands early', () {
      expect(countInDotOffset(2.5, 2.5, 3), (x: 2.5, lift: 0.0));
      expect(countInDotOffset(2.25, 2.5, 3).lift, greaterThan(0));
    });

    test('lead rests after the last number stretch the breath to the note',
        () {
      // Happy Farmer: count 1 2 3 to the pickup barline (beat 3), then a
      // hidden eighth rest — the D is heard at 3.5.
      expect(countInDotOffset(3.0, 3.5, 3).lift, greaterThan(0),
          reason: 'still in the air at the barline');
      expect(countInDotOffset(3.5, 3.5, 3), (x: 3.5, lift: 0.0));
    });

    test('rests on the first number before the count (an intro)', () {
      expect(countInDotOffset(-2, 3, 3), (x: 0.0, lift: 0.0));
    });
  });

  group('countInBarlines', () {
    test('between bars and closing a full last bar, in the gaps', () {
      expect(countInBarlines(const [1, 2, 3, 1, 2, 3], 3), [2.5, 5.5]);
    });

    test('a pickup leaves the last bar open', () {
      // 4/4 with a one-beat pickup: the count stops on 3, the music is beat 4.
      expect(countInBarlines(const [1, 2, 3], 4), isEmpty);
      expect(countInBarlines(const [1, 2, 3, 4, 1, 2], 4), [3.5]);
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
                  perBar: 3,
                ),
                height: 34,
                beatPosition: () => 1.5,
              ),
            ),
          ),
        );
    await t.pumpWidget(host(null));
    await t.pump(const Duration(milliseconds: 20));
    await t.pumpWidget(host(0.4));
    expect(find.text('Intro…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('the intro sits left, the count still shows on the right',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CountInLabel(
          tick: (
            labels: const [1, 2, 3],
            index: 0,
            startMeasure: 1,
            totalBeats: 3,
            introProgress: 0.5,
            perBar: 3,
          ),
          height: 34,
        ),
      ),
    ));
    final intro = t.getRect(find.text('Intro…'));
    final count = t.getRect(find.byType(CustomPaint).last);
    expect(intro.left, lessThan(100));
    expect(count.right, closeTo(800, 1));
  });

  testWidgets('the intro stays in place once the count proper begins',
      (t) async {
    Widget host(double? intro) => MaterialApp(
          home: Scaffold(
            body: CountInLabel(
              tick: (
                labels: const [1, 2, 3, 1, 2, 3],
                index: 0,
                startMeasure: 1,
                totalBeats: 6,
                introProgress: intro,
                perBar: 3,
              ),
              height: 34,
            ),
          ),
        );
    Rect countRect() => t.getRect(find.byType(CustomPaint).last);
    await t.pumpWidget(host(0.9));
    final during = countRect();
    await t.pumpWidget(host(null));
    expect(find.text('Intro…'), findsOneWidget);
    expect(countRect(), during);
  });
}
