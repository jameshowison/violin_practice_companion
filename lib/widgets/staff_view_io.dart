import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/section_palette.dart';
import '../services/midi_generator.dart';
import '../services/providers.dart';

class StaffView extends ConsumerStatefulWidget {
  final String musicXml;
  final ValueNotifier<HighlightEvent?> highlightNotifier;
  final String bridgeAsset;

  /// Current practice-range selection, highlighted on the staff. Null = none.
  final MeasureSelection? selection;

  /// Called with the measure number when the user taps a measure on the staff.
  final ValueChanged<int>? onMeasureTapped;

  /// Measures whose beat total doesn't match the time signature (OMR errors);
  /// drawn with a small warning marker.
  final Set<int> flaggedMeasures;

  /// Model measure numbers in document order (`parsed.measures[i].number`). The
  /// bridge works in positional indices because OSMD renumbers a short pickup;
  /// this list maps an OSMD index ↔ our measure number in both directions. In
  /// section-organized mode this is the unfolded performance order, so a
  /// repeated measure number appears at more than one index.
  final List<int> measureNumbers;

  /// Whether OSMD justifies the final system to full width. False in
  /// section-organized mode so the last line keeps its natural measure widths.
  final bool stretchLastSystem;

  /// Per-section background wash spans, in positional measure-index space
  /// (matching [measureNumbers]).
  final List<SectionTintSpan> sectionTints;

  /// Minimap scroll-to-measure request (measure index + a sequence so identical
  /// requests still fire); null until the minimap is tapped.
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
  late final WebViewController _controller;
  bool _osmdReady = false;
  String? _errorMessage;

  // Fire-and-forget JS. Swallows failures (e.g. a transient WKWebView error
  // during navigation/dispose, or a function a given bridge doesn't define) so
  // they don't surface as unhandled async exceptions.
  void _runJs(String js) {
    _controller.runJavaScript(js).catchError((_) {});
  }

  void _sendBottomInset(double px) {
    if (!_osmdReady) return;
    _runJs('window.setBottomInset($px)');
  }

  void _sendSpacing(double val) {
    if (!_osmdReady) return;
    _runJs('window.setSpacing($val)');
  }

  static String _colorHex(Color c) =>
      '#${(c.toARGB32() & 0x00FFFFFF).toRadixString(16).padLeft(6, '0')}';

  // The bridge addresses measures by positional index, so translate our model
  // measure numbers → indices via measureNumbers. -1 = "no selection".
  int _indexOf(int measureNumber) => widget.measureNumbers.indexOf(measureNumber);

  void _sendSelection() {
    if (!_osmdReady || !mounted) return;
    final sel = widget.selection;
    final start = sel == null ? -1 : _indexOf(sel.startMeasure);
    final end = sel == null ? -1 : _indexOf(sel.endMeasure);
    if (start < 0 || end < 0) {
      _runJs("window.setSelection(-1, -1, '')");
      return;
    }
    final color = _colorHex(Theme.of(context).colorScheme.primary);
    _runJs("window.setSelection($start, $end, '$color')");
  }

  void _sendFlagged() {
    if (!_osmdReady) return;
    final idx = widget.flaggedMeasures
        .map(_indexOf)
        .where((i) => i >= 0)
        .toList()
      ..sort();
    _runJs('window.setFlaggedMeasures([${idx.join(',')}])');
  }

  void _sendSectionTints() {
    if (!_osmdReady) return;
    final payload = jsonEncode([
      for (final s in widget.sectionTints)
        {'start': s.start, 'end': s.end, 'color': s.color}
    ]);
    _runJs('window.setSectionTints($payload)');
  }

  void _sendScrollNav() {
    if (!_osmdReady) return;
    final nav = widget.scrollNav;
    if (nav == null) return;
    _runJs('window.scrollToMeasureIndex(${nav.index})');
  }

  @override
  void initState() {
    super.initState();
    widget.highlightNotifier.addListener(_onHighlight);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'OsmdBridge',
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _osmdReady = true;
          _sendSpacing(ref.read(staffSpacingProvider));
          // Set overlay state BEFORE loading the score, so the score's
          // post-render redraw paints the section bars/selection/flags. (Sending
          // them after loadScore left _sections empty at first render — bars
          // only appeared on the next overlay event, e.g. a minimap tap.)
          _sendSelection();
          _sendFlagged();
          _sendSectionTints();
          _loadScore();
          _onHighlight();
          _sendBottomInset(ref.read(staffViewBottomInsetProvider));
        },
      ))
      ..loadFlutterAsset(widget.bridgeAsset);
  }

  void _onBridgeMessage(JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message);
      if (data is Map && data['type'] == 'measureTapped') {
        final i = data['index'];
        // Map the bridge's positional index back to our model measure number.
        if (i is int && i >= 0 && i < widget.measureNumbers.length) {
          widget.onMeasureTapped?.call(widget.measureNumbers[i]);
        }
        return;
      }
      if (data is Map && data['type'] == 'error') {
        setState(() => _errorMessage = data['message']?.toString());
        return;
      }
    } catch (_) {
      // Fall through: a bare (non-JSON) message is treated as an error string.
    }
    setState(() => _errorMessage = msg.message);
  }

  @override
  void didUpdateWidget(StaffView old) {
    super.didUpdateWidget(old);
    if (old.highlightNotifier != widget.highlightNotifier) {
      old.highlightNotifier.removeListener(_onHighlight);
      widget.highlightNotifier.addListener(_onHighlight);
      _onHighlight();
    }
    if (old.musicXml != widget.musicXml && _osmdReady) {
      // Set overlay state before reloading so the post-render redraw paints it.
      _sendSelection();
      _sendFlagged();
      _sendSectionTints();
      _loadScore();
    }
    // measureNumbers changes (e.g. after an edit re-parse) shift the index
    // mapping, so re-send both overlays when it does.
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
    if (!_osmdReady) return;
    final ev = widget.highlightNotifier.value;
    if (ev == null) {
      _runJs('window.clearHighlight()');
      return;
    }
    _runJs('window.positionCursor(${ev.beatPosition})');
  }

  void _loadScore() {
    if (!_osmdReady) return;
    // Send the stretch rule before the score so the first render uses it.
    _runJs('window.setStretchLastSystem(${widget.stretchLastSystem})');
    final escaped = widget.musicXml
        .replaceAll('\\', '\\\\')
        .replaceAll('`', '\\`')
        .replaceAll('\$', '\\\$');
    _runJs('window.loadScore(`$escaped`)');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(staffViewBottomInsetProvider, (_, px) => _sendBottomInset(px));
    ref.listen(staffSpacingProvider, (_, val) => _sendSpacing(val));
    if (_errorMessage != null) {
      return Center(
        child: Text('Staff view error: $_errorMessage',
            textAlign: TextAlign.center),
      );
    }
    return WebViewWidget(controller: _controller);
  }
}
