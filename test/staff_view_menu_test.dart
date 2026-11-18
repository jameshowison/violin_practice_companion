import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/section_engraving.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';
import 'package:violin_practice_companion/widgets/staff_view_menu.dart';

/// Eight bars in one part, no breaks: enough for the section planner.
String _xml(int bars) => '<score-partwise><part id="P1">'
    '${[for (var i = 1; i <= bars; i++) '<measure number="$i"/>'].join()}'
    '</part></score-partwise>';

void main() {
  group('solveSectionLayoutToFit', () {
    final widths = List<double>.filled(8, 300);
    const phoneSide = 375.0;
    final floor = staffScaleForSize(StaffSize.small, phoneSide);

    ({double scale, int lines}) fit(double viewportHeight) {
      final r = solveSectionLayoutToFit(
        musicXml: _xml(8),
        naturalWidths: widths,
        widthPx: 351,
        viewportHeightPx: viewportHeight,
        systemHeightPx: 60,
        minScale: floor,
      );
      return (scale: r.scale, lines: r.lines);
    }

    test('fits the whole piece in the budget when it can', () {
      final r = fit(600);
      expect(r.lines * 60 * r.scale / staffScaleProbe,
          lessThanOrEqualTo(600 * staffAutoFillFraction));
    });

    test('a taller screen gets notes at least as big', () {
      expect(fit(1200).scale, greaterThanOrEqualTo(fit(600).scale));
    });

    test('never goes below the floor, however short the screen', () {
      final tiny = fit(10);
      expect(tiny.scale, greaterThanOrEqualTo(floor - 1e-9));
      final atFloor = solveSectionLayout(
        musicXml: _xml(8),
        naturalWidths: widths,
        widthPx: 351,
        minScale: floor,
      );
      expect(tiny.lines, atFloor.lines);
    });
  });

  group('StaffViewMenuButton', () {
    Future<ProviderContainer> pump(WidgetTester tester,
        {DisplayMode mode = DisplayMode.staff,
        bool sections = true,
        bool printed = false}) async {
      final container = ProviderContainer(overrides: [
        sectionLayoutAvailableProvider.overrideWithValue(sections),
        printedLayoutAvailableProvider.overrideWithValue(printed),
      ]);
      addTearDown(container.dispose);
      // An SE's width: the panel has to fit.
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [StaffViewMenuButton(mode: mode)]),
            body: const SizedBox.expand(),
          ),
        ),
      ));
      return container;
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('staff_view_menu_button')));
      await tester.pumpAndSettle();
    }

    testWidgets('opens on Fit; a size picks Custom and stays open',
        (tester) async {
      final c = await pump(tester);
      expect(c.read(effectiveStaffViewModeProvider), StaffViewMode.fit);
      expect(c.read(staffSizeProvider), StaffSize.fit);
      await open(tester);

      await tester.tap(find.text('Large'));
      await tester.pumpAndSettle();
      expect(c.read(staffViewModeProvider), StaffViewMode.custom);
      expect(c.read(staffSizeProvider), StaffSize.large);
      // Non-modal, live: still open, so the next choice is one tap away.
      expect(find.text('Medium'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow on an SE');
      // Off the screen edge: the panel's padding plus an 8pt margin.
      final right =
          tester.getRect(find.byKey(const ValueKey('staff_size_fixed'))).right;
      expect(right, lessThanOrEqualTo(375 - 8));
    });

    testWidgets('Custom remembers its size and layout through Fit',
        (tester) async {
      final c = await pump(tester);
      await open(tester);
      await tester.tap(find.text('Small'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flowing'));
      await tester.pumpAndSettle();
      expect(c.read(staffBySectionProvider), isFalse);

      await tester.tap(find.text('Fit whole piece'));
      await tester.pumpAndSettle();
      expect(c.read(staffSizeProvider), StaffSize.fit);
      expect(c.read(staffBySectionProvider), isTrue,
          reason: 'Fit lays out by section where it can');

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(c.read(staffSizeProvider), StaffSize.small);
      expect(c.read(staffBySectionProvider), isFalse);
    });

    testWidgets('Like original scan: printed lines, then back to Fit',
        (tester) async {
      final c = await pump(tester, printed: true);
      await open(tester);
      await tester.tap(find.text('Like original scan'));
      await tester.pumpAndSettle();
      expect(c.read(staffByPrintedLinesProvider), isTrue);
      expect(c.read(staffBySectionProvider), isFalse);

      await tester.tap(find.text('Fit whole piece'));
      await tester.pumpAndSettle();
      expect(c.read(staffByPrintedLinesProvider), isFalse);
      expect(c.read(staffBySectionProvider), isTrue);
    });

    testWidgets('a piece that was not scanned has no Like original scan',
        (tester) async {
      final c = await pump(tester);
      c.read(staffViewModeProvider.notifier).state = StaffViewMode.original;
      await open(tester);
      expect(find.text('Like original scan'), findsNothing);
      expect(c.read(effectiveStaffViewModeProvider), StaffViewMode.fit,
          reason: 'a stale choice falls back to Fit');
    });

    testWidgets('no sections, no Layout row', (tester) async {
      await pump(tester, sections: false);
      await open(tester);
      expect(find.text('Small'), findsOneWidget);
      expect(find.text('Layout'), findsNothing);
    });

    testWidgets('tab offers Fit and the sizes only', (tester) async {
      await pump(tester, mode: DisplayMode.tab, printed: true);
      await open(tester);
      expect(find.text('Small'), findsOneWidget);
      expect(find.text('Layout'), findsNothing);
      expect(find.text('Like original scan'), findsNothing);
    });

    testWidgets('a tap outside closes it', (tester) async {
      await pump(tester);
      await open(tester);
      await tester.tapAt(const Offset(40, 600));
      await tester.pumpAndSettle();
      expect(find.text('Small'), findsNothing);
    });
  });
}
