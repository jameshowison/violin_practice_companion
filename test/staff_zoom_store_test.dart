import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';
import 'package:violin_practice_companion/services/staff_zoom_store.dart';

/// The staff zoom is saved per piece AND per orientation, because
/// measures-per-line means a different note size in each. These cover the split
/// itself and — the part with teeth — what happens to values written under the
/// old orientation-less key.
void main() {
  const portrait = StaffOrientation.portrait;
  const landscape = StaffOrientation.landscape;

  StaffZoomStore freshStore(Map<String, Object> initial) {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(initial);
    // A new store each time: it caches the SharedPreferences instance, and the
    // mock values are only picked up on a fresh `getInstance`.
    return StaffZoomStore();
  }

  group('per orientation', () {
    test('absent means auto, in both orientations', () async {
      final store = freshStore({});
      expect(await store.load('p1', portrait), isNull);
      expect(await store.load('p1', landscape), isNull);
    });

    test('the two orientations do not see each other', () async {
      final store = freshStore({});
      await store.save('p1', portrait, 2);
      await store.save('p1', landscape, 7);

      expect(await store.load('p1', portrait), 2);
      expect(await store.load('p1', landscape), 7);
    });

    test('pieces do not see each other', () async {
      final store = freshStore({});
      await store.save('p1', portrait, 2);

      expect(await store.load('p2', portrait), isNull);
    });

    test('null clears just that orientation, back to auto', () async {
      final store = freshStore({});
      await store.save('p1', portrait, 2);
      await store.save('p1', landscape, 7);

      await store.save('p1', portrait, null);

      expect(await store.load('p1', portrait), isNull);
      expect(await store.load('p1', landscape), 7,
          reason: 'clearing one orientation must not touch the other');
    });
  });

  group('pre-split values', () {
    // The key before the orientation split. Values written under it are the
    // whole reason `load` has a fallback.
    Map<String, Object> legacy(int v) => {'measuresPerLine.p1': v};

    test('seed both orientations', () async {
      final store = freshStore(legacy(3));
      expect(await store.load('p1', portrait), 3);
      expect(await store.load('p1', landscape), 3);
    });

    test('writing one orientation leaves the other on the seeded value',
        () async {
      final store = freshStore(legacy(3));
      await store.save('p1', landscape, 5);

      expect(await store.load('p1', landscape), 5);
      expect(await store.load('p1', portrait), 3,
          reason: 'the legacy value is promoted, not discarded');
    });

    test('the legacy key is retired on the first write', () async {
      final store = freshStore(legacy(3));
      await store.save('p1', landscape, 5);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('measuresPerLine.p1'), isNull);
    });

    // The one the fallback would silently break: `remove` succeeds, then the
    // next `load` falls straight back through to the legacy value and Auto
    // never sticks.
    test('going back to auto sticks, even from a legacy value', () async {
      final store = freshStore(legacy(3));
      await store.save('p1', portrait, null);

      expect(await store.load('p1', portrait), isNull);
      expect(await store.load('p1', landscape), 3,
          reason: 'the other orientation still keeps what was set before');
    });

    test('an explicit value already present wins over the legacy one', () async {
      final store = freshStore({...legacy(3), 'measuresPerLine.p1.portrait': 6});
      expect(await store.load('p1', portrait), 6);
      expect(await store.load('p1', landscape), 3);
    });
  });

  group('clear', () {
    test('takes both orientations and any legacy value', () async {
      final store = freshStore({'measuresPerLine.p1': 3});
      await store.save('p1', portrait, 2);
      await store.save('p1', landscape, 7);

      await store.clear('p1');

      expect(await store.load('p1', portrait), isNull);
      expect(await store.load('p1', landscape), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('measuresPerLine.p1'), isNull);
    });

    test('leaves other pieces alone', () async {
      final store = freshStore({});
      await store.save('p1', portrait, 2);
      await store.save('p2', portrait, 4);

      await store.clear('p1');

      expect(await store.load('p2', portrait), 4);
    });
  });
}
