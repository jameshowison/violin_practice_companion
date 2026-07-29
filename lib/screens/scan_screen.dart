import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/omr_service.dart';
import '../services/providers.dart';
import 'piece_detail_screen.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final _titleController = TextEditingController();
  OmrScanStage? _stage;
  bool _scanning = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  String get _title {
    final entered = _titleController.text.trim();
    if (entered.isNotEmpty) return entered;
    return 'Untitled ${DateTime.now().toIso8601String()}';
  }

  Future<void> _scan(OmrImageSource source) async {
    final title = _title;
    setState(() {
      _scanning = true;
      _stage = null;
    });

    try {
      final musicXml = await OmrService().scan(
        source: source,
        title: title,
        onProgress: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
        onSelectPdfPage: _selectPdfPage,
      );

      if (!mounted) return;
      if (musicXml == null) {
        // User cancelled at scan or crop — return to the piece list.
        Navigator.of(context).pop();
        return;
      }

      final piece = await ref.read(pieceRepositoryProvider).savePiece(title, musicXml);
      ref.invalidate(piecesProvider);

      if (!mounted) return;
      ref.read(selectedPieceProvider.notifier).state = piece;
      ref.read(measureSelectionProvider.notifier).state = null;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PieceDetailScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Scan failed'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _scan(source);
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
  }

  /// Prompt for which page of a multi-page PDF to recognise. Returns a
  /// 0-based page index, or null if the user cancels.
  Future<int?> _selectPdfPage(int pageCount) {
    return showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Choose a page (1–$pageCount)'),
        children: [
          for (var i = 0; i < pageCount; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(i),
              child: Text('Page ${i + 1}'),
            ),
        ],
      ),
    );
  }

  String _stageLabel(OmrScanStage? stage) => switch (stage) {
        null => 'Starting…',
        OmrScanStage.capturing => 'Capturing page…',
        OmrScanStage.preprocessing => 'Preprocessing image…',
        OmrScanStage.cropping => 'Crop to music…',
        OmrScanStage.segmenting => 'Detecting staves…',
        OmrScanStage.detecting => 'Detecting symbols…',
        OmrScanStage.recognising => 'Recognising notes…',
        OmrScanStage.assembling => 'Assembling MusicXML…',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan a Page')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('scan_title_field'),
              controller: _titleController,
              enabled: !_scanning,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Untitled',
              ),
            ),
            const SizedBox(height: 24),
            if (_scanning) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Center(child: Text(_stageLabel(_stage))),
            ] else ...[
              ElevatedButton.icon(
                key: const ValueKey('scan_camera_button'),
                onPressed: () => _scan(OmrImageSource.camera),
                icon: const Icon(Icons.document_scanner),
                label: const Text('Scan with Camera'),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                key: const ValueKey('scan_photos_button'),
                onPressed: () => _scan(OmrImageSource.photoLibrary),
                icon: const Icon(Icons.photo_library),
                label: const Text('Choose from Photos'),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                key: const ValueKey('scan_file_button'),
                onPressed: () => _scan(OmrImageSource.file),
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose File'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
