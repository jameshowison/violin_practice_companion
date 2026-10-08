/// Splits an engraved score's systems into printed pages. Pure Dart: it works
/// on extents the printer measures off the engraving.
///
/// * [lines] — each system's vertical extent on the tall engraved page, in
///   page units, in order. A page holding lines `a..b` is the slice
///   `lines[a].top .. lines[b].bottom`, so the gaps between systems on one page
///   are the engraving's own.
/// * [sectionStarts] — the lines a section begins on. Line 0 always counts.
/// * [firstPageHeight] / [pageHeight] — the room for systems on page 1 (which
///   also carries the title) and on every later page.
///
/// Rules, in order:
///  1. A system is never split.
///  2. A section that fits on a page is kept on one page: if it doesn't fit in
///     what is left of the current page, it starts the next.
///  3. A section taller than a page fills pages line by line — but never leaves
///     just its first line at the foot of a page, alone and cut off from the
///     rest of its section.
///  4. A system taller than a whole page still gets a page to itself (it will
///     be scaled to fit by the caller rather than dropped).
///
/// Returns each page's first and last line, inclusive.
List<({int first, int last})> paginateLines({
  required List<({double top, double bottom})> lines,
  required Set<int> sectionStarts,
  required double firstPageHeight,
  required double pageHeight,
}) {
  final pages = <({int first, int last})>[];
  if (lines.isEmpty) return pages;
  final starts = {0, ...sectionStarts.where((s) => s > 0 && s < lines.length)}
      .toList()
    ..sort();

  int? pageFirst; // first line on the page being filled, or null when empty
  var pageLast = -1;
  double room() => pages.isEmpty ? firstPageHeight : pageHeight;
  bool fits(int a, int b) => lines[b].bottom - lines[a].top <= room();
  void closePage() {
    if (pageFirst != null) pages.add((first: pageFirst!, last: pageLast));
    pageFirst = null;
  }

  for (var g = 0; g < starts.length; g++) {
    final from = starts[g];
    final to = (g + 1 < starts.length ? starts[g + 1] : lines.length) - 1;

    // Rule 2: the whole section, here or on a fresh page.
    if (pageFirst != null && !fits(pageFirst!, to)) {
      final freshFits = lines[to].bottom - lines[from].top <= pageHeight;
      // Rule 3's orphan guard, for a section that will have to split anyway:
      // only start it here if at least two of its lines fit.
      final twoFitHere = from < to && fits(pageFirst!, from + 1);
      if (freshFits || !twoFitHere) closePage();
    }

    for (var l = from; l <= to; l++) {
      if (pageFirst == null) {
        pageFirst = l;
        pageLast = l;
        continue; // rule 4: a line always fits on an empty page
      }
      // The check above already moved the section on if fewer than two of
      // its lines fit here, so a break inside the loop never strands its first.
      if (!fits(pageFirst!, l)) {
        closePage();
        pageFirst = l;
      }
      pageLast = l;
    }
  }
  closePage();
  return pages;
}
