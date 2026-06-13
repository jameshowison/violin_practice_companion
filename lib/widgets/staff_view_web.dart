import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web/web.dart' as web;

import '../models/section_palette.dart';
import '../services/midi_generator.dart';
import '../services/providers.dart';

class StaffView extends ConsumerStatefulWidget {
  final String musicXml;
  final ValueNotifier<HighlightEvent?> highlightNotifier;
  final String bridgeAsset;

  /// Current practice-range selection, highlighted on the staff. Null = none.
  final MeasureSelection? selection;

  /// Tap-to-select callback. Accepted for signature parity with the iOS
  /// variant, but the web iframe has no HTML→Dart return channel yet, so it is
  /// not invoked (deferred — see plan.md "iOS first, web later").
  final ValueChanged<int>? onMeasureTapped;

  /// Measures whose beat total doesn't match the time signature (OMR errors);
  /// drawn with a small warning marker.
  final Set<int> flaggedMeasures;

  /// Model measure numbers in document order (`parsed.measures[i].number`). The
  /// bridge works in positional indices because OSMD renumbers a short pickup;
  /// this list maps an index → our measure number. In section-organized mode
  /// this is the unfolded performance order.
  final List<int> measureNumbers;

  /// Whether OSMD justifies the final system to full width. False in
  /// section-organized mode so the last line keeps its natural measure widths.
  final bool stretchLastSystem;

  /// Per-section background wash spans, in positional measure-index space.
  final List<SectionTintSpan> sectionTints;

  /// Minimap scroll-to-measure request (measure index + sequence).
  final ({int index, int seq})? scrollNav;

  const StaffView({
    super.key,
    required this.musicXml,
    required this.highlightNotifier,
    this.bridgeAsset = 'assets/osmd/osmd_bridge.html',
    this.selection,
    this.onMeasureTapped,
    this.flaggedMeasures = const {},
    this.measureNumbers = const [],
    this.stretchLastSystem = true,
    this.sectionTints = const [],
    this.scrollNav,
  });

  @override
  ConsumerState<StaffView> createState() => _StaffViewState();
}

class _StaffViewState extends ConsumerState<StaffView> {
  static int _counter = 0;
  late final String _viewType;
  web.HTMLIFrameElement? _frame;
  bool _frameLoaded = false;

  @override
  void initState() {
    super.initState();
    _viewType = 'osmd-iframe-${_counter++}';
    widget.highlightNotifier.addListener(_onHighlight);

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final frame =
          web.document.createElement('iframe') as web.HTMLIFrameElement
            ..src = widget.bridgeAsset
            ..style.border = 'none'
            ..style.width = '100%'
            ..style.height = '100%';

      _frame = frame;

      frame.addEventListener(
        'load',
        ((web.Event _) {
          _frameLoaded = true;
          // Set overlay state before loading the score so the score's
          // post-render redraw paints the section bars/selection/flags.
          _sendSelection();
          _sendFlagged();
          _sendSectionTints();
          _postScore(widget.musicXml);
          _onHighlight();
        }).toJS,
      );

      return frame;
    });
  }

  @override
  void didUpdateWidget(StaffView old) {
    super.didUpdateWidget(old);
    if (old.highlightNotifier != widget.highlightNotifier) {
      old.highlightNotifier.removeListener(_onHighlight);
      widget.highlightNotifier.addListener(_onHighlight);
      _onHighlight();
    }
    if (old.musicXml != widget.musicXml && _frameLoaded) {
      // Set overlay state before reloading so the post-render redraw paints it.
      _sendSelection();
      _sendFlagged();
      _sendSectionTints();
      _postScore(widget.musicXml);
    }
    final mapChanged = !listEquals(old.measureNumbers, widget.measureNumbers);
    if (mapChanged || old.selection != widget.selection) _sendSelection();
    if (mapChanged || !setEquals(old.flaggedMeasures, widget.flaggedMeasures)) {
      _sendFlagged();
    }
    if (mapChanged || !listEquals(old.sectionTints, widget.sectionTints)) {
      _sendSectionTints();
    }
    if (widget.scrollNav != null && widget.scrollNav != old.scrollNav) {
      _sendScrollNav();
    }
  }

  @override
  void dispose() {
    widget.highlightNotifier.removeListener(_onHighlight);
    super.dispose();
  }

  void _onHighlight() {
    if (!_frameLoaded) return;
    final ev = widget.highlightNotifier.value;
    if (ev == null) {
      clearHighlight();
      return;
    }
    _postPositionCursor(ev.beatPosition);
  }

  void _postScore(String xml) {
    final cw = _frame?.contentWindow;
    if (cw == null) return;
    // Send the stretch rule before the score so the first render uses it.
    cw.postMessage(
      jsonEncode({
        'type': 'setStretchLastSystem',
        'val': widget.stretchLastSystem,
      }).toJS,
      '*'.toJS,
    );
    cw.postMessage(
      jsonEncode({'type': 'loadScore', 'xml': xml}).toJS,
      '*'.toJS,
    );
  }

  void _postPositionCursor(double beatPosition) {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'positionCursor', 'beat': beatPosition}).toJS,
      '*'.toJS,
    );
  }

  void clearHighlight() {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'clearHighlight'}).toJS,
      '*'.toJS,
    );
  }

  void _sendBottomInset(double px) {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'setBottomInset', 'px': px}).toJS,
      '*'.toJS,
    );
  }

  void _sendSpacing(double val) {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'setSpacing', 'val': val}).toJS,
      '*'.toJS,
    );
  }

  static String _colorHex(Color c) =>
      '#${(c.toARGB32() & 0x00FFFFFF).toRadixString(16).padLeft(6, '0')}';

  // The bridge addresses measures by positional index, so translate our model
  // measure numbers → indices via measureNumbers. -1 = "no selection".
  int _indexOf(int measureNumber) => widget.measureNumbers.indexOf(measureNumber);

  void _sendSelection() {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    final sel = widget.selection;
    final start = sel == null ? -1 : _indexOf(sel.startMeasure);
    final end = sel == null ? -1 : _indexOf(sel.endMeasure);
    final valid = start >= 0 && end >= 0;
    cw.postMessage(
      jsonEncode({
        'type': 'setSelection',
        'start': valid ? start : -1,
        'end': valid ? end : -1,
        'color': valid ? _colorHex(Theme.of(context).colorScheme.primary) : '',
      }).toJS,
      '*'.toJS,
    );
  }

  void _sendFlagged() {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    final idx = widget.flaggedMeasures
        .map(_indexOf)
        .where((i) => i >= 0)
        .toList()
      ..sort();
    cw.postMessage(
      jsonEncode({'type': 'setFlaggedMeasures', 'measures': idx}).toJS,
      '*'.toJS,
    );
  }

  void _sendSectionTints() {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    cw.postMessage(
      jsonEncode({
        'type': 'setSectionTints',
        'spans': [
          for (final s in widget.sectionTints)
            {'start': s.start, 'end': s.end, 'color': s.color}
        ],
      }).toJS,
      '*'.toJS,
    );
  }

  void _sendScrollNav() {
    final cw = _frame?.contentWindow;
    final nav = widget.scrollNav;
    if (!_frameLoaded || cw == null || nav == null) return;
    cw.postMessage(
      jsonEncode({'type': 'scrollToMeasureIndex', 'index': nav.index}).toJS,
      '*'.toJS,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(staffViewBottomInsetProvider, (_, px) => _sendBottomInset(px));
    ref.listen(staffSpacingProvider, (_, val) => _sendSpacing(val));
    return HtmlElementView(viewType: _viewType);
  }
}
