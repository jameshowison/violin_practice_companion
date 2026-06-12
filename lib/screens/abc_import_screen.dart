import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/abc_converter.dart';
import '../services/providers.dart';
import 'piece_detail_screen.dart';

/// Lets the user paste ABC notation, converts it to MusicXML (via the bundled
/// abcjs-based JS converter), and saves it as a new piece — reusing the same
/// save → navigate flow as the scan pathway.
class AbcImportScreen extends ConsumerStatefulWidget {
  const AbcImportScreen({super.key});

  @override
  ConsumerState<AbcImportScreen> createState() => _AbcImportScreenState();
}

class _AbcImportScreenState extends ConsumerState<AbcImportScreen> {
  final _abcController = TextEditingController();
  final _converter = AbcConverter();
  bool _importing = false;

  @override
  void dispose() {
    _abcController.dispose();
    _converter.dispose();
    super.dispose();
  }

  static String? _titleFromAbc(String abc) {
    for (final line in abc.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('T:')) {
        final title = t.substring(2).trim();
        if (title.isNotEmpty) return title;
      }
    }
    return null;
  }

  /// Title comes from the ABC itself: the converter reads the `T:` header; we
  /// also parse it directly as a fallback. A song-metadata editing mode can
  /// override it later.
  String _resolveTitle(String? converterTitle, String abc) {
    final fromConverter = converterTitle?.trim() ?? '';
    if (fromConverter.isNotEmpty) return fromConverter;
    final fromAbc = _titleFromAbc(abc);
    if (fromAbc != null && fromAbc.isNotEmpty) return fromAbc;
    return 'Untitled ${DateTime.now().toIso8601String()}';
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  Future<void> _import() async {
    final abc = _abcController.text.trim();
    if (abc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paste some ABC notation first.')),
      );
      return;
    }
    setState(() => _importing = true);
    try {
      final result = await _converter.convert(abc);
      final title = _resolveTitle(result.title, abc);

      final piece =
          await ref.read(pieceRepositoryProvider).savePiece(title, result.musicXml);
      ref.invalidate(piecesProvider);

      if (!mounted) return;
      if (result.warnings.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported with notes: ${result.warnings.join('; ')}')),
        );
      }
      ref.read(selectedPieceProvider.notifier).state = piece;
      ref.read(measureSelectionProvider.notifier).state = null;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PieceDetailScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import failed'),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Import from ABC')),
      // Scrollable content with the action button pinned below it. This keeps
      // the form usable when the on-screen keyboard shrinks the body (notably
      // in landscape, where it would otherwise overflow).
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'ABC notation is a compact text format for writing tunes. '
                      'Paste a tune below and it will be converted to staff '
                      'notation.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('Find tunes at ',
                            style: theme.textTheme.bodySmall),
                        _LinkButton(
                          label: 'abcnotation.com',
                          onTap: () => _openUrl('https://abcnotation.com'),
                        ),
                        Text(' and ', style: theme.textTheme.bodySmall),
                        _LinkButton(
                          label: 'thesession.org',
                          onTap: () => _openUrl('https://thesession.org'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('abc_input_field'),
                      controller: _abcController,
                      enabled: !_importing,
                      minLines: 6,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: 'ABC notation',
                        alignLabelWithHint: true,
                        hintText: 'X: 1\nT: My Tune\nM: 4/4\nL: 1/8\nK: D\n…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Single-voice tunes work best. Triplets and 1st/2nd '
                      'endings are approximated.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: _importing
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('abc_import_button'),
                        onPressed: _import,
                        icon: const Icon(Icons.library_music),
                        label: const Text('Import'),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _LinkButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              decoration: TextDecoration.underline,
              decorationColor: color,
            ),
      ),
    );
  }
}
