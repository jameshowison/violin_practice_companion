import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/midi_generator.dart';

class StaffView extends StatefulWidget {
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
  State<StaffView> createState() => _StaffViewState();
}

class _StaffViewState extends State<StaffView> {
  late final WebViewController _controller;
  bool _osmdReady = false;
  String? _errorMessage;

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
          _loadScore();
          _onHighlight();
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
      _controller.runJavaScript('window.clearHighlight()');
      return;
    }
    _controller.runJavaScript(
        'window.positionCursor(${ev.beatPosition}, ${ev.isLong || ev.noteIndex == 0})');
  }

  Future<void> _loadScore() async {
    if (!_osmdReady) return;
    final escaped = widget.musicXml
        .replaceAll('\\', '\\\\')
        .replaceAll('`', '\\`')
        .replaceAll('\$', '\\\$');
    await _controller.runJavaScript('window.loadScore(`$escaped`)');
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Center(
        child: Text('Staff view error: $_errorMessage',
            textAlign: TextAlign.center),
      );
    }
    return WebViewWidget(controller: _controller);
  }
}
