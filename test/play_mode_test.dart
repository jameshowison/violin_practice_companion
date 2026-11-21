import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_sync/score_sync.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/playback_service_base.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/widgets/media_controls.dart';

/// Records what the transport asks of it; plays nothing.
class _RecordingService extends PlaybackServiceBase {
  _RecordingService() : super(MidiGenerator.forTest());

  final plays = <({int from, int fromIndex, int? to, int toNote, int toIndex})>[];
  final ends = <({int? to, int toNote, int toIndex})>[];

  @override
  void play({
    int fromMeasure = 1,
    int fromNote = 0,
    int? toMeasure,
    int toNote = -1,
    int fromIndex = -1,
    int toIndex = -1,
    CountInPlan? countIn,
  }) =>
      plays.add((
        from: fromMeasure,
        fromIndex: fromIndex,
        to: toMeasure,
        toNote: toNote,
        toIndex: toIndex
      ));

  @override
  void setEnd({int? toMeasure, int toNote = -1, int toIndex = -1}) =>
      ends.add((to: toMeasure, toNote: toNote, toIndex: toIndex));

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {}
  @override
  void onStopped() {}
  @override
  void onTick(double playbackTime, MidiData data) {}
}

void main() {
  late _RecordingService service;
  late ProviderContainer container;

  setUp(() {
    service = _RecordingService();
    container = ProviderContainer(overrides: [
      playbackStartMeasureProvider.overrideWithValue(5),
      resolvedCountInProvider.overrideWithValue(null),
    ]);
    // Bars 5–6 on their second pass (performance indices 9–10).
    container.read(measureSelectionProvider.notifier).state =
        const MeasureSelection(5, 6, endNote: 2, startPerf: 9, endPerf: 10);
  });

  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Row(children: [
                  PlayModePill(service: service),
                  IconButton(
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => playSelection(ref, service),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );

  testWidgets('Once plays the selection, ending where it ends',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(service.plays.single,
        (from: 5, fromIndex: 9, to: 6, toNote: 2, toIndex: 10));
  });

  testWidgets('Through starts on the selected pass and has no end',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.east));
    expect(container.read(playModeProvider), PlayMode.through);
    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(service.plays.single,
        (from: 5, fromIndex: 9, to: null, toNote: -1, toIndex: -1));
  });

  testWidgets('switching mode tells a playing service its new end',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.east));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.repeat));
    await tester.pump();
    expect(container.read(playModeProvider), PlayMode.loop);
    expect(service.ends, [
      (to: null, toNote: -1, toIndex: -1),
      (to: 6, toNote: 2, toIndex: 10),
    ]);
  });

  testWidgets('on a phone upright, the modes are a menu that names them',
      (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(tester);
    expect(find.byType(SegmentedButton<PlayMode>), findsNothing);
    expect(find.byIcon(Icons.keyboard_tab), findsOneWidget); // Once, shown
    expect(find.byIcon(Icons.east), findsNothing);

    await tester.tap(find.byIcon(Icons.keyboard_tab));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play through to the end'));
    await tester.pumpAndSettle();
    expect(container.read(playModeProvider), PlayMode.through);
    expect(find.byIcon(Icons.east), findsOneWidget);
    expect(service.ends.single, (to: null, toNote: -1, toIndex: -1));
  });

  testWidgets('with nothing selected, Once also plays to the end',
      (tester) async {
    container.read(measureSelectionProvider.notifier).state = null;
    await pump(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(service.plays.single.to, isNull);
  });
}
