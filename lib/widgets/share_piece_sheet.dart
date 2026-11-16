import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../models/piece.dart';
import '../models/piece_media.dart';
import '../services/piece_share.dart';
import '../services/providers.dart';

/// Whether this platform can share a piece as a file. False on web.
bool get sharePieceAvailable => pieceShareSupported;

/// Share ▸ the piece and the recordings the sender picks, as one
/// `.stringlings` file through the system share sheet — AirDrop, Messages,
/// Mail, Files, Quick Share. See `piece_share_bundle.dart`.
Future<void> showSharePieceSheet(BuildContext context, Piece piece) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SharePieceSheet(piece: piece),
    );

class _SharePieceSheet extends ConsumerStatefulWidget {
  const _SharePieceSheet({required this.piece});

  final Piece piece;

  @override
  ConsumerState<_SharePieceSheet> createState() => _SharePieceSheetState();
}

class _SharePieceSheetState extends ConsumerState<_SharePieceSheet> {
  final _io = PieceShareIo();
  final _shareButtonKey = GlobalKey();
  List<PieceMedia>? _media;

  /// Media id → shared? and → include its video?
  final Map<String, bool> _include = {};
  final Map<String, bool> _video = {};
  int? _bytes;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await ref.read(pieceMediaProvider(widget.piece.id).future);
    final media = [
      for (final m in all)
        if (m.isRemovable && m.audio != null) m,
    ];
    if (!mounted) return;
    setState(() {
      _media = media;
      for (final m in media) {
        _include[m.id] = true;
        _video[m.id] = true;
      }
    });
    _estimate();
  }

  List<ShareMediaChoice> get _choices => [
        for (final m in _media ?? const <PieceMedia>[])
          if (_include[m.id] ?? false)
            ShareMediaChoice(m, includeVideo: _video[m.id] ?? false),
      ];

  Future<void> _estimate() async {
    final bytes = await _io.estimateBytes(_choices);
    if (mounted) setState(() => _bytes = bytes);
  }

  /// A separate video file: a teacher demo records one beside its audio. An
  /// imported .mp4 is its own audio, so leaving the video out saves nothing.
  static bool _hasSeparateVideo(PieceMedia m) =>
      m.video != null && m.video != m.audio;

  Future<void> _share() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(pieceRepositoryProvider);
      await repo.catalog();
      final piece = widget.piece;
      await _io.sweepOldExports();
      final path = await _io.export(
        pieceId: piece.id,
        title: piece.title,
        bundled: repo.isBundled(piece.id),
        musicXml: await repo.loadMusicXml(piece),
        sections: piece.sections,
        choices: _choices,
      );
      // iPad shows the share sheet as a popover, which needs an anchor.
      final box =
          _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: 'application/x-stringlings')],
        sharePositionOrigin: origin,
      ));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not share: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _size(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = _media;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share “${widget.piece.title}”',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Sends the music and the recordings you pick. Open it on '
              'another device with this app — AirDrop works nearby.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (media == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator.adaptive()),
              )
            else if (media.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('This piece has no recordings yet, so just the '
                    'music will be shared.'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in media) ...[
                      CheckboxListTile(
                        key: ValueKey('share_media_${m.id}'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(m.label),
                        value: _include[m.id] ?? false,
                        onChanged: _busy
                            ? null
                            : (v) {
                                setState(() => _include[m.id] = v ?? false);
                                _estimate();
                              },
                      ),
                      if (_hasSeparateVideo(m) && (_include[m.id] ?? false))
                        Padding(
                          padding: const EdgeInsets.only(left: 40),
                          child: SwitchListTile.adaptive(
                            key: ValueKey('share_video_${m.id}'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('Include video'),
                            value: _video[m.id] ?? false,
                            onChanged: _busy
                                ? null
                                : (v) {
                                    setState(() => _video[m.id] = v);
                                    _estimate();
                                  },
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (_busy)
                  const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5))
                else if (_bytes != null && _bytes! > 0)
                  Text('About ${_size(_bytes!)}',
                      style: theme.textTheme.bodySmall),
                const Spacer(),
                FilledButton.icon(
                  key: _shareButtonKey,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share…'),
                  onPressed: _busy || media == null ? null : _share,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
