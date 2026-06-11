import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/midi_generator.dart';
import '../services/providers.dart';

class StaffView extends ConsumerStatefulWidget {
  final String musicXml;
  final ValueNotifier<HighlightEvent?> highlightNotifier;
  final String bridgeAsset;

  const StaffView({
    super.key,
    required this.musicXml,
    required this.highlightNotifier,
    this.bridgeAsset = 'assets/osmd/osmd_bridge.html',
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

  @override
  void initState() {
    super.initState();
    widget.highlightNotifier.addListener(_onHighlight);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'OsmdBridge',
        onMessageReceived: (msg) {
          setState(() => _errorMessage = msg.message);
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _osmdReady = true;
          _sendSpacing(ref.read(staffSpacingProvider));
          _loadScore();
          _onHighlight();
          _sendBottomInset(ref.read(staffViewBottomInsetProvider));
        },
      ))
      ..loadFlutterAsset(widget.bridgeAsset);
  }

  @override
  void didUpdateWidget(StaffView old) {
    super.didUpdateWidget(old);
    if (old.highlightNotifier != widget.highlightNotifier) {
      old.highlightNotifier.removeListener(_onHighlight);
      widget.highlightNotifier.addListener(_onHighlight);
      _onHighlight();
    }
    if (old.musicXml != widget.musicXml && _osmdReady) _loadScore();
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
