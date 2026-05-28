import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class StaffView extends StatefulWidget {
  final String musicXml;
  final int? activeMeasure;

  const StaffView({super.key, required this.musicXml, this.activeMeasure});

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
        }).toJS,
      );

      return frame;
    });
  }

  @override
  void didUpdateWidget(StaffView old) {
    super.didUpdateWidget(old);
    if (old.musicXml != widget.musicXml && _frameLoaded) {
      _postScore(widget.musicXml);
    }
    if (old.activeMeasure != widget.activeMeasure && _frameLoaded) {
      final n = widget.activeMeasure;
      if (n != null) {
        highlightMeasure(n);
      } else {
        clearHighlight();
      }
    }
  }

  void _postScore(String xml) {
    final cw = _frame?.contentWindow;
    if (cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'loadScore', 'xml': xml}).toJS,
      '*'.toJS,
    );
  }

  void highlightMeasure(int n) {
    final cw = _frame?.contentWindow;
    if (!_frameLoaded || cw == null) return;
    cw.postMessage(
      jsonEncode({'type': 'highlightMeasure', 'n': n}).toJS,
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
