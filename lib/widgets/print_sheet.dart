import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../models/note_event.dart';
import '../models/section_palette.dart';
import '../models/violin_string_palette.dart';
import '../services/print_debug_dump.dart';
import '../services/providers.dart';
import '../services/score_printer.dart';
import '../services/staff_overlays.dart';
import '../services/staff_zoom.dart';

/// Whether the selected piece can be printed in [mode]: the staff and
/// annotation views, engraved natively. Tab, jianpu and the fingering view
/// have no print layout (yet).
bool printAvailableFor(WidgetRef ref, DisplayMode mode) =>
    ref.watch(staffRendererProvider) == StaffRenderer.verovio &&
    (mode == DisplayMode.staff || mode == DisplayMode.staffFingering);

/// The print options sheet: colour, paper (for sharing — the print dialog
/// picks its own), and whether to keep the screen's lines-per-section zoom.
Future<void> showPrintSheet(BuildContext context, DisplayMode mode) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _PrintSheet(mode: mode),
    );

class _PrintSheet extends ConsumerStatefulWidget {
  const _PrintSheet({required this.mode});

  final DisplayMode mode;

  @override
  ConsumerState<_PrintSheet> createState() => _PrintSheetState();
}

class _PrintSheetState extends ConsumerState<_PrintSheet> {
  PrintColour _colour = PrintColour.colour;
  bool _screenLines = false;
  late PdfPageFormat _paper = _defaultPaper();
  bool _busy = false;
  String? _error;

  /// Letter where it is the norm (the US, Canada, Mexico and a few others),
  /// A4 everywhere else.
  static PdfPageFormat _defaultPaper() {
    final country =
        WidgetsBinding.instance.platformDispatcher.locale.countryCode;
    const letter = {'US', 'CA', 'MX', 'PH', 'CL', 'CO', 'VE', 'GT', 'PR'};
    return letter.contains(country) ? PdfPageFormat.letter : PdfPageFormat.a4;
  }

  /// Reads everything the print needs from the providers, once.
  Future<PrintJob> _job() async {
    final piece = ref.read(selectedPieceProvider)!;
    final fingering = widget.mode == DisplayMode.staffFingering;
    final xml = await ref.read(printStaffXmlProvider(fingering).future);
    if (xml == null) throw StateError('No score to print');
    final parsed = await ref.read(parsedPieceProvider.future);
    final greyscale = _colour == PrintColour.greyscale;
    final overlays = staffOverlaysFor(
      ref.read,
      parsed: parsed,
      mode: widget.mode,
      sections: piece.sections,
      sectionColors: SectionPalette.colorsForSections(piece.sections),
      bySection: ref.read(sectionLayoutAvailableProvider),
      colourStyle: greyscale ? StringColourStyle.off : null,
    );
    return PrintJob(
      title: piece.title,
      musicXml: xml,
      parsed: parsed,
      sections: piece.sections,
      overlays: overlays,
      spacingUnits: verovioSpacingSystemFor(ref.read(staffSpacingProvider)),
      linesPerSection:
          _screenLines ? ref.read(linesPerSectionProvider).value : null,
      colour: _colour,
    );
  }

  Future<void> _run(Future<void> Function(PrintJob job) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(await _job());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List> _build(PrintJob job, PdfPageFormat format) async {
    final pdf = await buildScorePdf(job, format);
    await dumpPrintedPdf(pdf);
    return pdf;
  }

  String get _fileName =>
      '${ref.read(selectedPieceProvider)?.title ?? 'score'}.pdf'
          .replaceAll(RegExp(r'[/\\:]'), '-');

  @override
  Widget build(BuildContext context) {
    final screenLines = ref.watch(linesPerSectionProvider).value;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Print', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            SegmentedButton<PrintColour>(
              segments: const [
                ButtonSegment(
                    value: PrintColour.colour,
                    label: Text('Colour'),
                    icon: Icon(Icons.palette_outlined)),
                ButtonSegment(
                    value: PrintColour.greyscale,
                    label: Text('Greyscale'),
                    icon: Icon(Icons.contrast)),
              ],
              selected: {_colour},
              onSelectionChanged:
                  _busy ? null : (s) => setState(() => _colour = s.first),
            ),
            const SizedBox(height: 8),
            SegmentedButton<PdfPageFormat>(
              segments: const [
                ButtonSegment(
                    value: PdfPageFormat.letter, label: Text('Letter')),
                ButtonSegment(value: PdfPageFormat.a4, label: Text('A4')),
              ],
              selected: {_paper},
              onSelectionChanged:
                  _busy ? null : (s) => setState(() => _paper = s.first),
            ),
            if (screenLines != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    'Keep $screenLines line${screenLines == 1 ? '' : 's'} '
                    'per section'),
                subtitle: const Text(
                    'As on screen; otherwise the fewest that fit the page'),
                value: _screenLines,
                onChanged:
                    _busy ? null : (v) => setState(() => _screenLines = v),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (_busy)
                  const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5)),
                const Spacer(),
                TextButton.icon(
                  key: const ValueKey('print_share'),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share PDF'),
                  onPressed: _busy
                      ? null
                      : () => _run((job) async {
                            final pdf = await _build(job, _paper);
                            await Printing.sharePdf(
                                bytes: pdf, filename: _fileName);
                          }),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey('print_print'),
                  icon: const Icon(Icons.print),
                  label: const Text('Print…'),
                  onPressed: _busy
                      ? null
                      // Built BEFORE the dialog, for the paper chosen here,
                      // and handed over static. In dynamic layout the iOS
                      // plugin blocks the main thread on a semaphore while
                      // `onLayout` runs, and seconds of engraving there left
                      // the dialog's preview spinning.
                      : () => _run((job) async {
                            final pdf = await _build(job, _paper);
                            await Printing.layoutPdf(
                              name: _fileName,
                              format: _paper,
                              dynamicLayout: false,
                              onLayout: (_) async => pdf,
                            );
                          }),
                ),
              ],
            ),
            if (kDebugMode)
              TextButton(
                key: const ValueKey('print_debug_dump'),
                onPressed: _busy
                    ? null
                    : () => _run((job) => _build(job, _paper)),
                child: const Text('Debug: write PDF to Documents'),
              ),
          ],
        ),
      ),
    );
  }
}
