import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/piece_activity_store.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  final t0 = DateTime(2026, 11, 12, 9);
  final t1 = DateTime(2026, 11, 12, 10);

  test('opening records the time and survives a relaunch', () {
    PieceActivityNotifier(prefs).opened('lr', t0);

    final reloaded = PieceActivityNotifier(prefs).state;
    expect(reloaded['lr']!.openedAt, t0);
    expect(reloaded['lr']!.lastSection, isNull);
  });

  test('leaving records the section; reopening keeps it until a new one', () {
    final n = PieceActivityNotifier(prefs)
      ..opened('lr', t0)
      ..left('lr', 'B section')
      ..opened('lr', t1);

    expect(n.state['lr'], PieceActivity(openedAt: t1, lastSection: 'B section'));

    n.left('lr', null); // backed out with nothing selected
    expect(n.state['lr']!.lastSection, 'B section');
  });

  test('leaving a piece never opened records nothing', () {
    final n = PieceActivityNotifier(prefs)..left('ghost', 'A');
    expect(n.state, isEmpty);
    expect(prefs.getString(pieceActivityKey), isNull);
  });

  test('forget drops the piece', () {
    PieceActivityNotifier(prefs)
      ..opened('a', t0)
      ..opened('b', t1)
      ..forget('a');

    expect(PieceActivityNotifier(prefs).state.keys, ['b']);
  });

  test('only the newest pieceActivityLimit pieces are kept', () {
    final n = PieceActivityNotifier(prefs);
    for (var i = 0; i < pieceActivityLimit + 5; i++) {
      n.opened('p$i', t0.add(Duration(minutes: i)));
    }

    expect(n.state.length, pieceActivityLimit);
    expect(n.state.containsKey('p0'), isFalse);
    expect(n.state.containsKey('p${pieceActivityLimit + 4}'), isTrue);
  });

  test('a corrupt blob is an empty history, and bad rows are dropped', () async {
    SharedPreferences.setMockInitialValues({
      'flutter.$pieceActivityKey': jsonEncode({
        'ok': {'openedAt': t0.millisecondsSinceEpoch},
        'bad': {'openedAt': 'yesterday'},
      }),
    });
    final p = await SharedPreferences.getInstance();
    expect(PieceActivityNotifier(p).state.keys, ['ok']);

    SharedPreferences.setMockInitialValues({'flutter.$pieceActivityKey': '{nope'});
    expect(PieceActivityNotifier(await SharedPreferences.getInstance()).state,
        isEmpty);
  });

  test('without prefs it works for the session', () {
    final n = PieceActivityNotifier(null)..opened('lr', t0);
    expect(n.state.keys, ['lr']);
  });

  group('selectionLabel', () {
    const sections = [('A', 1), ('B section', 9), ('Coda', 17)];

    test('exactly one section reads as its label', () {
      expect(selectionLabel(sections, 9, 16), 'B section');
      expect(selectionLabel(sections, 17, 24), 'Coda'); // last runs to the end
    });

    test('anything else reads as bars', () {
      expect(selectionLabel(sections, 9, 12), 'Bars 9–12');
      expect(selectionLabel(sections, 1, 16), 'Bars 1–16');
      expect(selectionLabel(sections, 5, 5), 'Bar 5');
      expect(selectionLabel(const [], 3, 4), 'Bars 3–4');
    });
  });
}
