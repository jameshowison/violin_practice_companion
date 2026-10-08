import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/parsed_piece.dart';
import '../models/section.dart';
import '../models/section_palette.dart';
import '../widgets/staff_view_verovio.dart';
import 'print_paginator.dart';
import 'section_engraving.dart';
import 'staff_overlays.dart';
import 'staff_zoom.dart';
import 'verovio_engraver.dart';

/// How a printed page carries colour.
enum PrintColour {
  /// As on screen: string-coloured fingerings, section-coloured washes.
  colour,

  /// Nothing that needs colour to read: plain fingering labels with their
  /// string letters back (`StringColourStyle.off`), alternating light grey
  /// washes, and the whole page desaturated, chord bars included.
  greyscale,
}

/// Everything a print reads from the app, gathered once by the caller
/// (`print_sheet.dart`) so the PDF can be rebuilt for another paper size —
/// the system print dialog asks again whenever the user changes it — without
/// going back to the providers.
class PrintJob {
  const PrintJob({
    required this.title,
    required this.musicXml,
    required this.parsed,
    required this.sections,
    required this.overlays,
    required this.spacingUnits,
    required this.colour,
    this.linesPerSection,
  });

  final String title;

  /// From `printStaffXmlProvider`: broken before every section, opening
  /// clef/key/time kept.
  final String musicXml;
  final ParsedPiece? parsed;
  final List<Section> sections;

  /// From `staffOverlaysFor`, with the greyscale colour style already applied.
  final StaffOverlays overlays;

  /// The staff-spacing preference, resolved (`verovioSpacingSystemFor`).
  final int spacingUnits;

  /// The on-screen lines-per-section zoom, or null for the fewest that fit
  /// at [printMinStaffHeightMm].
  final int? linesPerSection;

  final PrintColour colour;
}

/// Smallest and largest printed staff, top line to bottom line. 6mm is a
/// little under a conventional part's 7mm, so a busy section still takes few
/// lines; 9mm is about where a beginner's book tops out.
const double printMinStaffHeightMm = 6.0;
const double printMaxStaffHeightMm = 9.0;

/// Page margin, all round.
const double printMarginMm = 15.0;

/// Raster resolution of each page.
const double printDpi = 300;

/// Builds the PDF for [job] on [format]. Each page is the engraving plus the
/// app's own lanes (`paintStaffScore`), rasterised at [printDpi] — the
/// fingerings and chords exist only as Flutter painters, never in Verovio's
/// SVG, so a raster of the composed canvas is what keeps them.
Future<Uint8List> buildScorePdf(PrintJob job, PdfPageFormat format) async {
  final layout = await layoutScoreForPrint(job, format);
  final doc = pw.Document(title: job.title, creator: 'Violin Practice Companion');
  for (var i = 0; i < layout.pages.length; i++) {
    final png = await _renderPage(layout, i);
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.all(layout.marginPt),
        build: (_) => pw.Image(
          pw.MemoryImage(png),
          width: layout.printableWidth,
          height: layout.printableHeight,
          fit: pw.BoxFit.contain,
          alignment: pw.Alignment.topLeft,
        ),
      ),
    );
  }
  return doc.save();
}

/// A score engraved and paginated for one paper size, in PDF points.
class PrintLayout {
  PrintLayout._({
    required this.job,
    required this.score,
    required this.image,
    required this.scale,
    required this.marginPt,
    required this.gutter,
    required this.engraveWidth,
    required this.printableWidth,
    required this.printableHeight,
    required this.lines,
    required this.sectionMarks,
    required this.pages,
  });

  final PrintJob job;
  final EngravedScore score;
  final ScalableImage image;

  /// viewBox → points.
  final double scale;
  final double marginPt;

  /// Left strip, inside the margin, that carries the section letters.
  final double gutter;
  final double engraveWidth;
  final double printableWidth;
  final double printableHeight;

  /// Each system's slice of the tall engraving, in points.
  final List<({double top, double bottom})> lines;

  /// Section letter → the line it starts.
  final List<({int line, String label})> sectionMarks;
  final List<({int first, int last})> pages;

  int get pageCount => pages.length;
}

/// Room on page 1 for the title, and on every page for the footer, in points.
const double _titleHeight = 40;
const double _footerHeight = 16;

/// Engraves [job] at [format]'s printable width by the section layout's rule
/// (`solveSectionLayout`) and splits its systems into pages
/// (`paginateLines`). Exposed apart from [buildScorePdf] for tests and for
/// the debug log.
Future<PrintLayout> layoutScoreForPrint(
    PrintJob job, PdfPageFormat format) async {
  final engraver = VerovioEngraver.instance;
  const mm = PdfPageFormat.mm;
  final margin = printMarginMm * mm;
  final printableW = format.width - 2 * margin;
  final printableH = format.height - 2 * margin;
  final gutter = job.sections.length >= 2 ? 18.0 : 0.0;
  final engraveW = printableW - gutter;

  // 1. Probe, bare, to price the annotation reserve — as the staff view does.
  final probe = await engraver.engrave(
    job.musicXml,
    widthPx: engraveW,
    scale: staffScaleProbe,
    spacingSystem: job.spacingUnits,
  );
  var reserveSpacing = 0;
  var reserveMargin = 0;
  if (scoreReservesAnnotationRoom(job.musicXml)) {
    final room = annotationRoomOf(probe);
    final reserve = annotationReserveFor(
      interSystemRoomSpaces: room.inter,
      firstSystemRoomSpaces: room.first,
      wantSpaces: annotationWantSpaces(probe, staffScaleProbe),
    );
    reserveSpacing = reserve.spacingUnits;
    reserveMargin = reserve.pageMarginTopUnits;
  }
  final spacing =
      (job.spacingUnits + reserveSpacing).clamp(0, verovioSpacingSystemMax);

  // 2. Natural bar widths, from the whole piece on one unjustified line.
  final line = await engraver.engrave(
    job.musicXml,
    widthPx: sectionNaturalLineWidthPx,
    scale: staffScaleProbe,
    spacingSystem: spacing,
    breaks: 'none',
  );
  final widths = [
    for (final m in line.measures) m.rect.width * 100 / staffScaleProbe,
  ];

  // 3. Plan the lines and the scale, between the paper's staff-size bounds.
  final solved = solveSectionLayout(
    musicXml: job.musicXml,
    naturalWidths: widths,
    widthPx: engraveW,
    minScale: _scaleForStaffMm(printMinStaffHeightMm),
    maxScale: _scaleForStaffMm(printMaxStaffHeightMm),
    linesPerSection: job.linesPerSection,
  );
  final systemHeightPx = probe.systemHeightViewBox +
      reserveSpacing * spacesPerSpacingSystemUnit * probe.staffSpaceViewBox;
  final score = await engraver.engrave(
    solved.xml,
    widthPx: engraveW,
    scale: solved.scale,
    spacingSystem: spacing,
    pageMarginTop: (verovioPageMarginTopDefault + reserveMargin)
        .clamp(0, verovioPageMarginTopMax),
    pageHeightUnits: pageHeightUnitsFor(
      measureCount: probe.measures.length,
      measuresPerLine: math.max(1, (probe.measures.length / solved.lines).ceil()),
      systemHeightPx: systemHeightPx,
    ),
    breaks: 'encoded',
  );
  if (VerovioEngraver.debugLogging) {
    debugPrint('[print] ${format.width.round()}x${format.height.round()}pt '
        'w=${engraveW.round()} lines=${solved.lines} '
        'scale=${solved.scale.toStringAsFixed(1)} '
        'staff=${(staffHeightUnits * solved.scale / 100 / mm).toStringAsFixed(1)}mm');
  }

  final image = ScalableImage.fromSvgString(
    score.svg,
    currentColor: Colors.black,
    warnF: (_) {},
  );
  final scale = engraveW / score.viewBox.width;

  // 4. Each system's slice: its ink, plus the lanes drawn above it (which sit
  //    above the ink top — the chord bar hangs over the chord register), never
  //    reaching back into the system before.
  final stack = annotationStackOf(score, scale);
  final space = score.staffSpaceViewBox * scale;
  final above = stack.barHeight + stack.channelHeight + stack.gap + space;
  final lines = <({double top, double bottom})>[];
  for (var l = 0; l < score.lineContent.length; l++) {
    final c = score.lineContent[l];
    final floor = l == 0 ? 0.0 : score.lineContent[l - 1].bottom * scale;
    lines.add((
      top: math.max(floor, c.top * scale - above),
      bottom: c.bottom * scale + space * 0.5,
    ));
  }

  final marks = _sectionMarks(score, job);
  final pages = paginateLines(
    lines: lines,
    sectionStarts: {for (final m in marks) m.line},
    firstPageHeight: printableH - _titleHeight - _footerHeight,
    pageHeight: printableH - _footerHeight,
  );
  return PrintLayout._(
    job: job,
    score: score,
    image: image,
    scale: scale,
    marginPt: margin,
    gutter: gutter,
    engraveWidth: engraveW,
    printableWidth: printableW,
    printableHeight: printableH,
    lines: lines,
    sectionMarks: marks,
    pages: pages,
  );
}

/// Verovio `scale` for a staff [mm] tall on paper: the engrave is laid out in
/// points (one viewBox px per point), and a staff is [staffHeightUnits] per
/// 100 of scale.
double _scaleForStaffMm(double mm) =>
    mm * PdfPageFormat.mm * 100 / staffHeightUnits;

/// Where each section starts, as an engraved line and its letter.
List<({int line, String label})> _sectionMarks(
    EngravedScore score, PrintJob job) {
  final parsed = job.parsed;
  if (parsed == null || job.sections.length < 2) return const [];
  final map = job.overlays.measureMap;
  final marks = <({int line, String label})>[];
  for (final r in resolveSectionRanges(job.sections, parsed.measures)) {
    final at = map.range(r.startMeasure, r.startNote, r.endMeasure, r.endNote);
    if (at == null) continue;
    final line = score.lineOfMeasure(at.startMeasureIndex);
    if (line < 0 || marks.any((m) => m.line == line)) continue;
    marks.add((line: line, label: r.label));
  }
  return marks;
}

/// Luminance-preserving desaturation (Rec. 709 weights).
const _greyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// One page, the whole printable area, as PNG at [printDpi].
Future<Uint8List> _renderPage(PrintLayout layout, int index) async {
  final job = layout.job;
  final page = layout.pages[index];
  final w = layout.printableWidth;
  final h = layout.printableHeight;
  const dpr = printDpi / 72;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(dpr);
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
  final grey = job.colour == PrintColour.greyscale;
  if (grey) {
    canvas.saveLayer(
        Rect.fromLTWH(0, 0, w, h), Paint()..colorFilter = _greyscale);
  }

  var y = 0.0;
  if (index == 0) {
    _paintText(canvas, job.title,
        rect: Rect.fromLTWH(0, 0, w, _titleHeight),
        size: 18,
        weight: FontWeight.w600,
        align: TextAlign.center);
    y = _titleHeight;
  }

  // The systems, slice [top, bottom] of the tall engraving — scaled down only
  // if a single system is taller than the page (see `paginateLines`).
  final top = layout.lines[page.first].top;
  final bottom = layout.lines[page.last].bottom;
  final room = h - y - _footerHeight;
  final fit = math.min(1.0, room / (bottom - top));
  canvas.save();
  canvas.translate(0, y);
  canvas.scale(fit);
  canvas.clipRect(Rect.fromLTWH(0, 0, w / fit, bottom - top));
  canvas.translate(0, -top);
  for (final m in layout.sectionMarks) {
    if (m.line < page.first || m.line > page.last) continue;
    _paintSectionMark(canvas, m.label, layout.lines[m.line].top, layout);
  }
  canvas.translate(layout.gutter, 0);
  final score = layout.score;
  paintStaffScore(
    canvas,
    Size(layout.engraveWidth, score.viewBox.height * layout.scale),
    score: score,
    image: layout.image,
    scale: layout.scale,
    sectionTints: grey
        ? _alternatingGreys(job.overlays.sectionTints)
        : job.overlays.sectionTints,
    chordRuns: job.overlays.chordRuns,
    fingeringAnnotations: job.overlays.annotations,
    stringRuns: job.overlays.stringRuns,
    stringColourStyle: job.overlays.colourStyle,
  );
  canvas.restore();

  _paintText(
    canvas,
    layout.pageCount > 1
        ? '${job.title} — page ${index + 1} of ${layout.pageCount}'
        : job.title,
    rect: Rect.fromLTWH(0, h - _footerHeight, w, _footerHeight),
    size: 8,
    color: const Color(0xFF666666),
    align: TextAlign.right,
  );
  if (grey) canvas.restore();

  final picture = recorder.endRecording();
  final img = await picture.toImage((w * dpr).ceil(), (h * dpr).ceil());
  picture.dispose();
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bytes!.buffer.asUint8List();
}

/// A section's wash in greyscale: every other section a light grey, so
/// neighbours stay distinguishable without a hue.
List<SectionTintRegion> _alternatingGreys(List<SectionTintRegion> tints) => [
      for (var i = 0; i < tints.length; i += 2)
        (
          startMeasureIndex: tints[i].startMeasureIndex,
          startNote: tints[i].startNote,
          endMeasureIndex: tints[i].endMeasureIndex,
          endNote: tints[i].endNote,
          color: '#555555',
        ),
    ];

/// A rehearsal-mark-style boxed letter in the gutter, level with the top of
/// the section's first system.
void _paintSectionMark(
    Canvas canvas, String label, double lineTop, PrintLayout layout) {
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: const TextStyle(
          fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  const pad = 2.5;
  final box = Rect.fromLTWH(
    0,
    lineTop + 2,
    math.min(layout.gutter - 3, math.max(tp.width + pad * 2, tp.height)),
    tp.height + pad,
  );
  canvas.drawRect(
    box,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.black,
  );
  tp.paint(canvas,
      Offset(box.center.dx - tp.width / 2, box.center.dy - tp.height / 2));
}

void _paintText(
  Canvas canvas,
  String text, {
  required Rect rect,
  required double size,
  FontWeight weight = FontWeight.normal,
  Color color = Colors.black,
  TextAlign align = TextAlign.left,
}) {
  final tp = TextPainter(
    text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, fontWeight: weight, color: color)),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: 1,
    ellipsis: '…',
  )..layout(minWidth: rect.width, maxWidth: rect.width);
  tp.paint(canvas, Offset(rect.left, rect.center.dy - tp.height / 2));
}
