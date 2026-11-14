import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';

/// The page photos a scanned piece was recognised from, as acquired (before
/// the crop), so the player can check the engraving against the printed page.
/// One page per swipe; pinch to zoom.
class ScanPhotoScreen extends ConsumerStatefulWidget {
  final String pieceId;
  final String title;
  const ScanPhotoScreen({super.key, required this.pieceId, required this.title});

  @override
  ConsumerState<ScanPhotoScreen> createState() => _ScanPhotoScreenState();
}

class _ScanPhotoScreenState extends ConsumerState<ScanPhotoScreen> {
  late final Future<List<Uint8List>> _pages =
      ref.read(scanSourceStoreProvider).originals(widget.pieceId);
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Uint8List>>(
      future: _pages,
      builder: (context, snap) {
        final pages = snap.data ?? const <Uint8List>[];
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title,
                    // The app theme's title colour, not the bar's foreground, wins otherwise.
                    style: const TextStyle(fontSize: 14, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(
                  pages.length > 1
                      ? 'Original photo · page ${_page + 1} of ${pages.length}'
                      : 'Original photo',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
          body: switch (snap) {
            AsyncSnapshot(hasError: true) => const _Message("Couldn't read the photo."),
            AsyncSnapshot(connectionState: ConnectionState.done)
                when pages.isEmpty =>
              const _Message('No photo was kept for this piece.'),
            AsyncSnapshot(connectionState: ConnectionState.done) => PageView.builder(
                key: const ValueKey('scan_photo_pages'),
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => InteractiveViewer(
                  maxScale: 6,
                  child: Center(
                    child: Image.memory(
                      pages[i],
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          const _Message("This photo's format can't be shown."),
                    ),
                  ),
                ),
              ),
            _ => const Center(child: CircularProgressIndicator.adaptive()),
          },
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, style: const TextStyle(color: Colors.white70)),
        ),
      );
}
