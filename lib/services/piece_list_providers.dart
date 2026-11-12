import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece.dart';
import '../models/piece_filter.dart';
import '../models/piece_library.dart';
import '../models/piece_meta.dart';
import 'piece_activity_store.dart';
import 'providers.dart';

/// The piece list's filters: tab, book, keywords, key, recording. Session
/// state, like the search box.
///
/// Opens on Recents once something has been played on this device, and on
/// All before that, so a fresh install never starts on an empty tab.
final pieceFilterProvider = StateProvider<PieceFilter>((ref) => PieceFilter(
      tab: ref.read(pieceActivityProvider).isEmpty
          ? PieceTab.all
          : PieceTab.recent,
    ));

/// Key, time and composer for every piece, read from each score's header.
///
/// Loaded for all pieces at once because the Key filter and its counts need
/// them all. Rebuilt whenever [piecesProvider] reloads (an edit, a scan, a
/// delete), which is also when a score can have changed. A piece whose score
/// can't be read is simply absent: it shows no key and fails a key filter.
final allPieceMetaProvider = FutureProvider<Map<String, PieceMeta>>((ref) async {
  final pieces = await ref.watch(piecesProvider.future);
  final repo = ref.watch(pieceRepositoryProvider);
  final out = <String, PieceMeta>{};
  for (final p in pieces) {
    try {
      out[p.id] = PieceMeta.fromHeader(
        await repo.loadMusicXml(p),
        fallbackComposer: await repo.composerFor(p.id),
      );
    } catch (_) {
      // Unreadable score: no metadata, the row still lists.
    }
  }
  return out;
});

/// Which pieces have a recording to play along with: bundled tracks, or media
/// the user imported or recorded.
///
/// Cheaper than [pieceMediaProvider] per row, which also loads alignments.
/// The list invalidates this when it comes back from a piece, since that is
/// where media gets added or removed.
final recordedPiecesProvider = FutureProvider<Set<String>>((ref) async {
  final pieces = await ref.watch(piecesProvider.future);
  final repo = ref.watch(pieceRepositoryProvider);
  final store = ref.watch(pieceMediaStoreProvider);
  return {
    for (final p in pieces)
      if (await repo.audioSyncFolderFor(p.id) != null ||
          await store.hasAny(p.id))
        p.id,
  };
});

/// The list the screen renders. Waits only for the pieces: the library,
/// metadata and recordings decorate it as they arrive, never gate it.
final pieceListProvider = Provider<AsyncValue<PieceListResult>>((ref) {
  final library = ref.watch(libraryProvider).valueOrNull ?? PieceLibrary.empty;
  final meta = ref.watch(allPieceMetaProvider).valueOrNull ?? const {};
  final recorded = ref.watch(recordedPiecesProvider).valueOrNull ?? const {};
  final activity = ref.watch(pieceActivityProvider);
  final filter = ref.watch(pieceFilterProvider);
  final query = ref.watch(pieceSearchProvider);
  return ref.watch(piecesProvider).whenData((List<Piece> pieces) => filterPieces(
        pieces: pieces,
        library: library,
        meta: meta,
        activity: activity,
        recorded: recorded,
        filter: filter,
        query: query,
      ));
});
