import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/widgets/measure_edit_row.dart';

void main() {
  const note = NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false);

  Future<void> pump(WidgetTester t, {bool start = false, bool end = false}) =>
      t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MeasureEditRow(
            notes: const [note, note],
            selectedIndex: 0,
            onSelect: (_) {},
            repeatStart: start,
            repeatEnd: end,
          ),
        ),
      ));

  testWidgets('no repeat barlines by default', (t) async {
    await pump(t);
    expect(find.byKey(const ValueKey('repeat_start_bar')), findsNothing);
    expect(find.byKey(const ValueKey('repeat_end_bar')), findsNothing);
  });

  testWidgets('repeat barlines flank the cards, each on its own', (t) async {
    await pump(t, end: true);
    expect(find.byKey(const ValueKey('repeat_start_bar')), findsNothing);
    final endBar = t.getRect(find.byKey(const ValueKey('repeat_end_bar')));
    expect(endBar.left,
        greaterThanOrEqualTo(t.getRect(find.byKey(const ValueKey('note_1'))).right));

    await pump(t, start: true, end: true);
    final startBar = t.getRect(find.byKey(const ValueKey('repeat_start_bar')));
    expect(startBar.right,
        lessThanOrEqualTo(t.getRect(find.byKey(const ValueKey('note_0'))).left));
  });
}
