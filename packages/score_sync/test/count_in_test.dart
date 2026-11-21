import 'package:test/test.dart';
import 'package:score_sync/score_sync.dart';

void main() {
  group('barCounting', () {
    test('x/4 and x/2 count their denominator', () {
      expect(barCounting(4, 4), (unit: 8, perBar: 4));
      expect(barCounting(3, 4), (unit: 8, perBar: 3));
      expect(barCounting(5, 4), (unit: 8, perBar: 5));
      expect(barCounting(2, 2), (unit: 16, perBar: 2));
    });

    test('compound meters count dotted beats: a jig is two, not six', () {
      expect(barCounting(6, 8), (unit: 12, perBar: 2));
      expect(barCounting(9, 8), (unit: 12, perBar: 3));
      expect(barCounting(12, 8), (unit: 12, perBar: 4));
    });

    test('a simple x/8 still counts eighths', () {
      expect(barCounting(3, 8), (unit: 4, perBar: 3));
      expect(barCounting(7, 8), (unit: 4, perBar: 7));
    });
  });

  group('countInPlan', () {
    /// The displayed sequence, e.g. `1 .. 2 .. 3`.
    String shown(CountInPlan? p) => p == null ? 'off' : p.labels.join(' .. ');

    CountInPlan? plan(int beats, int beatType,
            {int pickupUnits = 0, int minBeats = countInMinBeats}) =>
        countInPlan(
            beatsPerMeasure: beats,
            beatType: beatType,
            pickupUnits: pickupUnits,
            minBeats: minBeats);

    test('4/4 with a one-beat pickup counts 1 2 3 (the pickup is 4)', () {
      final p = plan(4, 4, pickupUnits: 8)!;
      expect(shown(p), '1 .. 2 .. 3');
      // The count ends exactly where the pickup bar begins: three beats.
      expect(p.totalUnits, 24);
      expect(p.unit, 8);
    });

    test('4/4 with no pickup counts the whole bar', () {
      final p = plan(4, 4)!;
      expect(shown(p), '1 .. 2 .. 3 .. 4');
      expect(p.totalUnits, 32);
    });

    test('4/4 with a two-beat pickup takes another bar, landing on 3', () {
      final p = plan(4, 4, pickupUnits: 16)!;
      expect(shown(p), '1 .. 2 .. 3 .. 4 .. 1 .. 2');
      expect(p.totalUnits, 48); // two bars less the pickup
    });

    test('3/4 with a one-beat pickup takes another bar, landing on 3', () {
      final p = plan(3, 4, pickupUnits: 8)!;
      expect(shown(p), '1 .. 2 .. 3 .. 1 .. 2');
      expect(p.totalUnits, 40);
    });

    test('2/4 takes two bars to clear the floor', () {
      expect(shown(plan(2, 4)), '1 .. 2 .. 1 .. 2');
    });

    test('a jig counts dotted beats over two bars', () {
      // 6/8 less a one-eighth pickup: two dotted beats a bar, so two bars.
      final p = plan(6, 8, pickupUnits: 4)!;
      expect(shown(p), '1 .. 2 .. 1 .. 2');
      expect(p.unit, 12);
      // The last counted beat is cut short by the pickup — 44 units, not 48.
      expect(p.totalUnits, 44);
    });

    test('a sub-beat pickup shortens only the last beat, not the count', () {
      // A lone sixteenth in 4/4: still "1 2 3 4", with the music starting two
      // units after four rather than on it.
      final p = plan(4, 4, pickupUnits: 2)!;
      expect(shown(p), '1 .. 2 .. 3 .. 4');
      expect(p.totalUnits, 30);
    });

    test('a bigger minimum buys whole bars, not part ones', () {
      expect(shown(plan(4, 4, minBeats: 8)), '1 .. 2 .. 3 .. 4 .. 1 .. 2 .. 3 .. 4');
      // 6 is met by two bars (8 beats) — the count never ends off the barline.
      expect(shown(plan(4, 4, minBeats: 6)), '1 .. 2 .. 3 .. 4 .. 1 .. 2 .. 3 .. 4');
      expect(shown(plan(4, 4, minBeats: 6, pickupUnits: 8)),
          '1 .. 2 .. 3 .. 4 .. 1 .. 2 .. 3');
    });

    test('the minimum sizes the count in BARS, so a pickup can undercut it', () {
      // Two bars is what "at least 8" asks for; the anacrusis then takes its
      // beat back, giving seven. Growing to a third bar to reach a literal eight
      // would put the count 11 beats long and off the barline — the caught bug.
      final p = plan(4, 4, minBeats: 8, pickupUnits: 8)!;
      expect(shown(p), '1 .. 2 .. 3 .. 4 .. 1 .. 2 .. 3');
      expect(p.totalUnits, 56);
    });

    test('0 is off', () {
      expect(plan(4, 4, minBeats: 0), isNull);
      expect(plan(4, 4, minBeats: -1), isNull);
    });

    test('a below-floor minimum still gets a countable three', () {
      expect(shown(plan(4, 4, minBeats: 1, pickupUnits: 8)), '1 .. 2 .. 3');
    });

    test('a pickup can never swallow the whole count', () {
      // A nonsense pickup as long as the bar is clamped, so there is always
      // something to count.
      final p = plan(4, 4, pickupUnits: 32)!;
      expect(p.labels, isNotEmpty);
      expect(p.totalUnits, greaterThan(0));
    });
  });

  group('countInUnitSeconds', () {
    test('a quarter is eight units', () {
      // 120 bpm ⇒ a quarter every 0.5 s ⇒ 0.0625 s per 32nd unit.
      expect(countInUnitSeconds(120) * 8, closeTo(0.5, 1e-9));
    });

    test("Devil's Dream at 115 bpm counts three beats in ~1.57 s", () {
      final p = countInPlan(beatsPerMeasure: 4, beatType: 4, pickupUnits: 8)!;
      expect(p.totalUnits * countInUnitSeconds(115), closeTo(1.565, 0.01));
    });

    test('degenerate tempo is zero, not infinite', () {
      expect(countInUnitSeconds(0), 0);
    });
  });
}
