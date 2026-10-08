import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/print_paginator.dart';

/// [n] systems [h] tall with [gap] between them, from y = 0.
List<({double top, double bottom})> systems(int n,
        {double h = 100, double gap = 20}) =>
    [
      for (var i = 0; i < n; i++)
        (top: i * (h + gap), bottom: i * (h + gap) + h),
    ];

void main() {
  test('everything on one page when it fits', () {
    final pages = paginateLines(
      lines: systems(4),
      sectionStarts: {2},
      firstPageHeight: 1000,
      pageHeight: 1000,
    );
    expect(pages, [(first: 0, last: 3)]);
  });

  test('page 1 holds less than later pages (the title takes room)', () {
    // 4 lines = 460 tall. Page 1 fits 3 (340), later pages fit all 4.
    final pages = paginateLines(
      lines: systems(6),
      sectionStarts: const {},
      firstPageHeight: 350,
      pageHeight: 500,
    );
    expect(pages, [(first: 0, last: 2), (first: 3, last: 5)]);
  });

  test('a section that fits on a page is not split across two', () {
    // Sections: lines 0-1, 2-4. Page fits 4 lines (460). Greedy would put
    // lines 0-3 on page 1 and split the second section.
    final pages = paginateLines(
      lines: systems(5),
      sectionStarts: {2},
      firstPageHeight: 470,
      pageHeight: 470,
    );
    expect(pages, [(first: 0, last: 1), (first: 2, last: 4)]);
  });

  test('a section taller than a page fills pages line by line', () {
    // One section of 7 lines; a page fits 3.
    final pages = paginateLines(
      lines: systems(7),
      sectionStarts: const {},
      firstPageHeight: 350,
      pageHeight: 350,
    );
    expect(pages,
        [(first: 0, last: 2), (first: 3, last: 5), (first: 6, last: 6)]);
  });

  test('an oversized section starts on the current page when 2+ lines fit', () {
    // Section A: line 0. Section B: lines 1-6 (too tall for any page of 3).
    final pages = paginateLines(
      lines: systems(7),
      sectionStarts: {1},
      firstPageHeight: 350,
      pageHeight: 350,
    );
    expect(pages,
        [(first: 0, last: 2), (first: 3, last: 5), (first: 6, last: 6)]);
  });

  test("an oversized section's first line is never left alone at the foot",
      () {
    // Section A: lines 0-1. Section B: lines 2-8. Page fits 3 lines, so only
    // B's first line would fit on page 1 — it moves to page 2 instead.
    final pages = paginateLines(
      lines: systems(9),
      sectionStarts: {2},
      firstPageHeight: 350,
      pageHeight: 350,
    );
    expect(pages, [
      (first: 0, last: 1),
      (first: 2, last: 4),
      (first: 5, last: 7),
      (first: 8, last: 8),
    ]);
  });

  test('a system taller than a page still gets a page', () {
    final pages = paginateLines(
      lines: systems(2, h: 500),
      sectionStarts: const {},
      firstPageHeight: 300,
      pageHeight: 300,
    );
    expect(pages, [(first: 0, last: 0), (first: 1, last: 1)]);
  });

  test('no lines, no pages', () {
    expect(
      paginateLines(
          lines: const [],
          sectionStarts: const {},
          firstPageHeight: 100,
          pageHeight: 100),
      isEmpty,
    );
  });
}
