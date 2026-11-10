import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/media_playback_service.dart';
import '../services/providers.dart';

/// Debug-only Marionette extension `realignAll`: recomputes the cached
/// alignment of every recording in the library with the running build.
///
/// Alignments are cached per device and never invalidated when the aligner
/// changes, so devices drift apart. Realign on one device, then let the dev
/// library sync carry the results everywhere (see README, "Dev library").
///
/// Returns at once; progress is one `[realign]` log line per alignment key,
/// then `[realign] done …`. Pass `pieceId` to realign just that piece.
/// A full run also deletes alignments no current medium uses (left by deleted
/// or re-imported media), so the sync stops carrying them.
void registerRealignAll(ProviderContainer container) {
  var running = false;
  registerMarionetteExtension(
    name: 'realignAll',
    description: 'Recompute every recording\'s cached score alignment '
        '(optional param pieceId). Runs in the background; watch the '
        '[realign] log lines.',
    callback: (params) async {
      if (running) {
        return const MarionetteExtensionResult.error(0, 'already running');
      }
      running = true;
      _realignAll(container, params['pieceId'])
          .whenComplete(() => running = false);
      return const MarionetteExtensionResult.success({'started': true});
    },
  );
}

Future<void> _realignAll(ProviderContainer c, String? onlyPieceId) async {
  final service = MediaPlaybackService(c.read(midiGeneratorProvider),
      store: c.read(mediaAlignmentStoreProvider));
  final repo = c.read(pieceRepositoryProvider);
  final parser = c.read(musicXmlParserProvider);
  final jianpu = c.read(jianpuConverterProvider);
  final fingering = c.read(fingeringMapperProvider);
  var ok = 0, failed = 0, pruned = 0;
  final inUse = <String>{};
  try {
    await jianpu.init();
    await fingering.init();
    for (final piece in await c.read(piecesProvider.future)) {
      if (onlyPieceId != null && piece.id != onlyPieceId) continue;
      final seen = <String>{};
      final all = await c.read(pieceMediaProvider(piece.id).future);
      inUse.addAll(all.map((m) => m.alignmentKey));
      final media = [
        for (final m in all)
          if (!m.isSynthesized && m.analysis != null && seen.add(m.alignmentKey))
            m,
      ];
      if (media.isEmpty) continue;
      // As parsedPieceProvider does. The fingering preference is left at its
      // default: it changes labels, not the pitches and timing DTW aligns.
      final parsed = fingering
          .map(jianpu.convert(parser.parse(await repo.loadMusicXml(piece))));
      for (final m in media) {
        try {
          final a = await service.recomputeAlignment(parsed, m);
          if (a == null) {
            failed++;
            debugPrint('[realign] FAILED ${m.alignmentKey}');
          } else {
            ok++;
            debugPrint('[realign] ${m.alignmentKey}: ${a.anchors.length} anchors '
                '${a.anchors.first.audioSec.toStringAsFixed(2)}–'
                '${a.anchors.last.audioSec.toStringAsFixed(2)}s'
                '${a.hasCompressedAnchors ? ' (compressed: review)' : ''}');
          }
        } catch (e) {
          failed++;
          debugPrint('[realign] FAILED ${m.alignmentKey}: $e');
        }
      }
    }
    if (onlyPieceId == null) {
      const prefix = 'mediaAlignment.';
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(prefix) &&
            !inUse.contains(key.substring(prefix.length))) {
          await prefs.remove(key);
          pruned++;
          debugPrint('[realign] pruned orphan ${key.substring(prefix.length)}');
        }
      }
    }
  } finally {
    service.dispose();
  }
  debugPrint('[realign] done: $ok realigned, $failed failed, $pruned pruned');
}
