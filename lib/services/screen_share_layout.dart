import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'print_paginator.dart';
import 'staff_zoom.dart';
import 'verovio_engraver.dart';

/// "Fit to screen": the piece engraved plainly enough for ANOTHER device to
/// scan off this screen — a teacher shares a tune by holding up the phone,
/// and the student's Scan with Camera reads it like a printed page.
///
/// What the scanner (homr) needs, measured by running its recogniser over
/// screenshots (integration_test/screen_scan_test.dart):
///  * a clef on every system — homr finds staves by their clefs, so the
///    practice view's clef-in-the-title-bar layout scans as "no staves";
///  * nothing drawn over or between the staves (fingering lanes, washes);
///  * a staff big enough relative to the crop's WIDTH, because homr rescales
///    every crop to 1920 px wide. On this view's own rendering (dev-iphone-se
///    screenshots), a dense piece — 90 bars of 2/4, ten bars a line — lost
///    37 % of its notes with a staff 3.8 % of the width tall, 11 % at 4.2 %,
///    none at 4.6 % or 5.3 %. (Chrome's rendering of the same engraving
///    scans cleanly far smaller, so don't tune this headlessly.)
///
/// So the staff height is pinned between [maxStaffFraction] and
/// [minStaffFraction] of the width: the largest size at which the piece
/// fits on one screen, else screen-sized pages, as few as the floor allows,
/// scanned one after another as a multi-page scan.
class ScreenShareLayout {
  ScreenShareLayout._({
    required this.score,
    required this.scale,
    required this.lines,
    required this.pages,
    required this.staffHeight,
  });

  final EngravedScore score;

  /// viewBox → logical pixels.
  final double scale;

  /// Each system's slice of the engraving, in logical pixels.
  final List<({double top, double bottom})> lines;

  /// Each screen's first and last system, inclusive.
  final List<({int first, int last})> pages;

  /// Five-line staff height, in logical pixels.
  final double staffHeight;

  int get pageCount => pages.length;

  /// Logical height of page [i]'s systems.
  double pageHeight(int i) =>
      lines[pages[i].last].bottom - lines[pages[i].first].top;
}

/// Staff height as a fraction of the engraving's width: the comfortable size,
/// used whenever the piece fits (and for every page when it doesn't)...
const double maxStaffFraction = 0.053;

/// ...and the smallest the layout will shrink to, to save a page. Below
/// this the recogniser starts dropping whole systems of a dense piece.
const double minStaffFraction = 0.046;

/// Gap between systems, in Verovio's half-spaces on top of what the notes
/// themselves need. Tighter than the practice view's 12 (no annotation lanes
/// to make room for), so a longer piece still fits on one screen.
const int _spacingSystem = 4;

/// Lays out [musicXml] for a [width] × [height] logical-pixel area.
Future<ScreenShareLayout> layoutForScreen(
  String musicXml, {
  required double width,
  required double height,
}) async {
  final engraver = VerovioEngraver.instance;
  double scaleFor(double fraction) => fraction * width * 100 / staffHeightUnits;

  Future<ScreenShareLayout> engraveAt(double engraveScale) async {
    final score = await engraver.engrave(
      musicXml,
      widthPx: width,
      scale: engraveScale,
      spacingSystem: _spacingSystem,
      // A clef and key signature on every line, as printed music has: the
      // scanner keys staff detection on the clef.
      stripRepeatClefs: false,
      // Never stretch the last line: a short one spread over the full width
      // pulls a beamed group so wide that homr reads its eighths as
      // quarters (Song of the Wind's last bar, 4 of 49 notes).
      minLastJustification: 1,
    );
    final scale = width / score.viewBox.width;
    final space = score.staffSpaceViewBox * scale;
    final lines = <({double top, double bottom})>[];
    for (var l = 0; l < score.lineContent.length; l++) {
      final c = score.lineContent[l];
      final floor = l == 0 ? 0.0 : score.lineContent[l - 1].bottom * scale;
      lines.add((
        top: math.max(floor, c.top * scale - space),
        bottom: c.bottom * scale + space,
      ));
    }
    final pages = paginateLines(
      lines: lines,
      sectionStarts: const {},
      firstPageHeight: height,
      pageHeight: height,
    );
    return ScreenShareLayout._(
      score: score,
      scale: scale,
      lines: lines,
      pages: pages,
      staffHeight: score.staffHeightViewBox * scale,
    );
  }

  final maxScale = scaleFor(maxStaffFraction);
  final minScale = scaleFor(minStaffFraction);
  var best = await engraveAt(maxScale);
  if (best.pageCount > 1) {
    // Shrink toward the floor only if that saves a page. A smaller staff fits
    // more bars per line AND makes each line shorter, so the height goes
    // roughly as the square of the scale.
    final target = best.pageCount - 1;
    final total = best.lines.last.bottom - best.lines.first.top;
    var s = math.max(
        minScale, maxScale * math.sqrt(target * height / total) * 0.98);
    for (var tries = 0; tries < 5; tries++) {
      final next = await engraveAt(s);
      if (next.pageCount <= target) {
        best = next;
        break;
      }
      if (s <= minScale) break;
      s = math.max(minScale, s * 0.94);
    }
  }
  if (VerovioEngraver.debugLogging) {
    debugPrint('[fit] ${width.round()}x${height.round()} '
        'staff=${best.staffHeight.toStringAsFixed(1)}px '
        '(${(best.staffHeight / width * 100).toStringAsFixed(1)}% of width) '
        'lines=${best.lines.length} pages=${best.pageCount}');
  }
  return best;
}
