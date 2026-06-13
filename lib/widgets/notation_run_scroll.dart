import 'package:flutter/material.dart';
import '../models/piece_layout.dart';

/// Shared scroll/navigation plumbing for the jianpu & fingering views, which lay
/// section runs out in a `SingleChildScrollView`. Uses per-row and per-run-header
/// [GlobalKey]s with [Scrollable.ensureVisible] (rather than fragile pixel math)
/// for playback-follow and minimap navigation, and reports the top-most visible
/// run on scroll so the minimap can show "where we are".
mixin NotationRunScroll<T extends StatefulWidget> on State<T> {
  ScrollController get scrollController;
  PieceLayout get layout;
  ValueChanged<int>? get onVisibleRunChanged;

  final Map<int, GlobalKey> _rowKeys = {};
  final Map<int, GlobalKey> _runHeaderKeys = {};
  int? _lastReportedRun;

  GlobalKey rowKey(int i) => _rowKeys.putIfAbsent(i, () => GlobalKey());
  GlobalKey runHeaderKey(int i) =>
      _runHeaderKeys.putIfAbsent(i, () => GlobalKey());

  /// Scroll the run's header to the top of the viewport (minimap tap).
  void scrollToRun(int runIndex) {
    final ctx = _runHeaderKeys[runIndex]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        alignment: 0.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut);
  }

  /// Scroll the row holding [measureNumber] into view (playback follow), leaving
  /// a little context above it.
  void scrollToMeasure(int measureNumber) {
    final rowIndex = layout.rows
        .indexWhere((row) => row.any((m) => m.number == measureNumber));
    if (rowIndex < 0) return;
    final ctx = _rowKeys[rowIndex]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        alignment: 0.1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut);
  }

  /// The top-most run whose header sits at/above the viewport top → minimap.
  void reportVisibleRun() {
    final cb = onVisibleRunChanged;
    if (cb == null || !scrollController.hasClients) return;
    final selfBox = context.findRenderObject() as RenderBox?;
    if (selfBox == null || !selfBox.attached) return;
    final viewportTop = selfBox.localToGlobal(Offset.zero).dy;
    var best = 0;
    for (var i = 0; i < layout.runs.length; i++) {
      final rb = _runHeaderKeys[i]?.currentContext?.findRenderObject()
          as RenderBox?;
      if (rb == null || !rb.attached) continue;
      final top = rb.localToGlobal(Offset.zero).dy;
      if (top <= viewportTop + 16) {
        best = i;
      } else {
        break;
      }
    }
    if (best != _lastReportedRun) {
      _lastReportedRun = best;
      cb(best);
    }
  }
}
