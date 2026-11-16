import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/playback_service.dart';
import 'package:violin_practice_companion/services/providers.dart';

/// "Silent" is the synthesized score with its sound off: picking it mutes the
/// synth, picking anything else (or leaving the piece) unmutes it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const piece =
      Piece(id: 'p', title: 'P', musicXmlAssetPath: 'x.xml', sections: []);

  test('picking Silent mutes the synth; picking Simulated unmutes it',
      () async {
    final synth = PlaybackService(MidiGenerator.forTest());
    final c = ProviderContainer(overrides: [
      playbackServiceProvider.overrideWithValue(synth),
      pieceMediaProvider.overrideWith((ref, id) async =>
          const [PieceMedia.synthesized, PieceMedia.silent]),
    ]);
    addTearDown(c.dispose);
    c.read(selectedPieceProvider.notifier).state = piece;
    await c.read(pieceMediaProvider('p').future);

    final sub = c.listen(activePlaybackServiceProvider, (_, _) {});
    expect(synth.muted, isFalse);

    c.read(selectedMediaIdProvider('p').notifier).state = 'silent';
    expect(c.read(activePlaybackServiceProvider), same(synth));
    expect(synth.muted, isTrue);

    c.read(selectedMediaIdProvider('p').notifier).state = 'synthesized';
    c.read(activePlaybackServiceProvider);
    expect(synth.muted, isFalse);

    c.read(selectedMediaIdProvider('p').notifier).state = 'silent';
    c.read(activePlaybackServiceProvider);
    expect(synth.muted, isTrue);
    sub.close();
    await Future<void>.delayed(Duration.zero); // let autoDispose run
    expect(synth.muted, isFalse);
  });
}
