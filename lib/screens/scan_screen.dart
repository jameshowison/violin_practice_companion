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

  Future<void> _scan(OmrImageSource source) async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a title first.')),
      );
      return;
    }
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
                hintText: 'Required',
              ),
            ),
            const SizedBox(height: 12),
            const _NaturalAccidentalHint(),
            const SizedBox(height: 12),
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

/// The scan model was never trained to detect natural (♮) signs (they were
/// stripped from its upstream training data — see homr's `strip_naturals`).
/// A note that should show a natural will silently follow the key signature
/// instead, so that has to be said somewhere rather than read as a bad scan.
class _NaturalAccidentalHint extends StatelessWidget {
  const _NaturalAccidentalHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: const ValueKey('natural_accidental_hint'),
      dense: true,
      leading: Icon(Icons.info_outline, size: 18, color: theme.hintColor),
      title: Text(
        "Natural signs (♮) aren't detected — an affected note will follow "
        'the key signature instead. Not a scan error; fix it in the note '
        'editor after scanning.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
    );
  }
}
