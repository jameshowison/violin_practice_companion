import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class StaffView extends StatefulWidget {
  final String musicXml;
  final int? activeMeasure;

  const StaffView({super.key, required this.musicXml, this.activeMeasure});

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
        },
      ))
      ..loadFlutterAsset('assets/osmd/osmd_bridge.html');
  }

  @override
  void didUpdateWidget(StaffView old) {
    super.didUpdateWidget(old);
    if (old.musicXml != widget.musicXml && _osmdReady) _loadScore();
    if (old.activeMeasure != widget.activeMeasure && _osmdReady) {
      final n = widget.activeMeasure;
      if (n != null) {
        _controller.runJavaScript('window.highlightMeasure($n)');
      } else {
        _controller.runJavaScript('window.clearHighlight()');
      }
    }
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
