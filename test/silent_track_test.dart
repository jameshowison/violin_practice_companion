import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/silent_playback_service.dart';

/// "Silent" is the score's clock alone: a player that makes no audio, so no
/// speaker is held.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const piece =
      Piece(id: 'p', title: 'P', musicXmlAssetPath: 'x.xml', sections: []);

  test('the cursor runs on the clock, at the tempo', () async {
    final parsed = MusicXmlParser().parse(
        File('assets/library/lightly_row/score.musicxml').readAsStringSync());
    final silent = SilentPlaybackService(MidiGenerator.forTest());
    addTearDown(silent.dispose);
    silent.setTempo(240);
    await silent.loadPiece(parsed);
    silent.play();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    // 2.5 s at 240 bpm in 4/4 is two and a half bars.
    expect(silent.currentMeasureNotifier.value, inInclusiveRange(2, 4));
    silent.stop();
  });

  test('Silent is the clock-only player; the score is the rendered one',
      () async {
    final silent = SilentPlaybackService(MidiGenerator.forTest());
    final c = ProviderContainer(overrides: [
      silentPlaybackServiceProvider.overrideWith((_) => silent),
      pieceMediaProvider.overrideWith((ref, id) async =>
          const [PieceMedia.synthesized, PieceMedia.silent]),
      renderedScoreServiceProvider
          .overrideWith((_) => throw StateError('not under test')),
    ]);
    addTearDown(c.dispose);
    c.read(selectedPieceProvider.notifier).state = piece;
    await c.read(pieceMediaProvider('p').future);
    final sub = c.listen(activePlaybackServiceProvider, (_, _) {},
        onError: (_, _) {});

    c.read(selectedMediaIdProvider('p').notifier).state = 'silent';
    expect(c.read(activePlaybackServiceProvider), same(silent));
    sub.close();
  });
}
