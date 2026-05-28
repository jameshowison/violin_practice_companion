import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../services/midi_generator.dart';

class StaffView extends StatefulWidget {
  final String musicXml;
  final ValueNotifier<HighlightEvent?> highlightNotifier;

  const StaffView({super.key, required this.musicXml, required this.highlightNotifier});

  @override
  State<StaffView> createState() => _StaffViewState();
}

class _StaffViewState extends State<StaffView> {
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
            ..src = 'assets/osmd/osmd_bridge.html'
            ..style.border = 'none'
            ..style.width = '100%'
            ..style.height = '100%';

      _frame = frame;

      frame.addEventListener(
        'load',
        ((web.Event _) {
          _frameLoaded = true;
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
      _postScore(widget.musicXml);
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
    _postPositionCursor(ev.beatPosition, ev.isLong || ev.noteIndex == 0);
  }

  void _postScore(String xml) {
    final cw = _frame?.contentWindow;
    if (cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'loadScore', 'xml': xml}).toJS,
      '*'.toJS,
    );
  }

  void _postPositionCursor(double beatPosition, bool isLong) {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'positionCursor', 'beat': beatPosition, 'isLong': isLong}).toJS,
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

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
