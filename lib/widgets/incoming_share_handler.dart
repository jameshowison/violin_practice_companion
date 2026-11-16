import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/piece_detail_screen.dart';
import '../services/incoming_share.dart';
import '../services/piece_list_providers.dart';
import '../services/piece_share.dart';
import '../services/providers.dart';

/// The app's one Navigator, so a share file that arrives while any screen is
/// up can show its dialogs and then open the piece.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Imports each shared piece (`.stringlings`) the system opens in the app, one
/// at a time, then opens it. Sits in `MaterialApp.builder`, above every route,
/// and reaches the Navigator through [appNavigatorKey].
class IncomingShareHandler extends ConsumerStatefulWidget {
  const IncomingShareHandler({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingShareHandler> createState() =>
      _IncomingShareHandlerState();
}

class _IncomingShareHandlerState extends ConsumerState<IncomingShareHandler> {
  StreamSubscription<String>? _sub;
  final _queue = <String>[];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    if (!pieceShareSupported) return;
    _sub = IncomingShareChannel.instance.paths.listen((path) {
      _queue.add(path);
      _pump();
    });
    IncomingShareChannel.instance.start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        // The first frame (and the Navigator) may not be up yet when a file
        // launches the app.
        while (appNavigatorKey.currentContext == null) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (!mounted) return;
        }
        await _import(_queue.removeAt(0));
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _import(String path) async {
    final io = PieceShareIo();
    final nav = appNavigatorKey.currentState!;
    final navContext = appNavigatorKey.currentContext!;
    final messenger = ScaffoldMessenger.maybeOf(navContext);

    var progressShown = true;
    unawaited(showDialog<void>(
      context: navContext,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            CircularProgressIndicator.adaptive(),
            SizedBox(width: 20),
            Expanded(child: Text('Adding the shared piece…')),
          ]),
        ),
      ),
    ));
    void closeProgress() {
      if (progressShown) {
        progressShown = false;
        nav.pop();
      }
    }

    OpenedShare? share;
    try {
      share = await io.open(path);
      final pieces = await ref.read(piecesProvider.future);
      final result = await io.apply(
        share,
        repo: ref.read(pieceRepositoryProvider),
        pieces: pieces,
        onScoreConflict: (title) => _askOnConflict(nav.context, title),
      );
      closeProgress();
      if (result == null) return; // cancelled at the conflict question

      ref.invalidate(piecesProvider);
      ref.invalidate(pieceMediaProvider(result.pieceId));
      ref.invalidate(recordedPiecesProvider);
      final piece = (await ref.read(piecesProvider.future))
          .where((p) => p.id == result.pieceId)
          .firstOrNull;
      messenger?.showSnackBar(SnackBar(content: Text(_summary(result))));
      if (piece == null || !mounted) return;
      nav.popUntil((r) => r.isFirst);
      ref.read(selectedPieceProvider.notifier).state = piece;
      ref.read(measureSelectionProvider.notifier).state = null;
      unawaited(nav.push(
        MaterialPageRoute<void>(builder: (_) => const PieceDetailScreen()),
      ));
    } on FormatException catch (e) {
      closeProgress();
      await _showError(nav.context, e.message);
    } catch (e) {
      closeProgress();
      await _showError(nav.context, '$e');
    } finally {
      await share?.dispose();
      await io.discardIncoming(path);
    }
  }

  static String _summary(ShareImportResult r) {
    String recs(int n) => n == 1 ? '1 recording' : '$n recordings';
    final title = '“${r.title}”';
    return switch (r.score) {
      ShareScoreAction.create => r.added == 0
          ? 'Added $title'
          : 'Added $title with ${recs(r.added)}',
      ShareScoreAction.replace => r.added == 0
          ? 'Updated the music for $title'
          : 'Updated $title and added ${recs(r.added)}',
      ShareScoreAction.keep => r.added == 0
          ? 'You already have everything in $title'
          : 'Added ${recs(r.added)} to $title',
    };
  }

  static Future<ShareConflictChoice?> _askOnConflict(
          BuildContext context, String title) =>
      showDialog<ShareConflictChoice>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('You already have this piece'),
          content: Text('The shared “$title” has different music from yours. '
              'Replace yours, or keep both as separate pieces? '
              'Either way, its recordings are added.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('share_keep_both'),
              onPressed: () =>
                  Navigator.of(ctx).pop(ShareConflictChoice.keepBoth),
              child: const Text('Keep both'),
            ),
            TextButton(
              key: const ValueKey('share_replace'),
              onPressed: () =>
                  Navigator.of(ctx).pop(ShareConflictChoice.replace),
              child: const Text('Replace'),
            ),
          ],
        ),
      );

  static Future<void> _showError(BuildContext context, String message) =>
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Couldn’t add the shared piece'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => widget.child;
}
