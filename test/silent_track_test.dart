import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/playback_service.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/rendered_score_playback_service.dart';

/// "Silent" is the synthesized score with its sound off: picking it mutes
/// what plays the score, picking anything else (or leaving the piece)
/// unmutes it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const piece =
      Piece(id: 'p', title: 'P', musicXmlAssetPath: 'x.xml', sections: []);

  Future<ProviderContainer> containerFor(PlaybackService synth,
      {required bool rendered,
      RenderedScorePlaybackService? renderedService}) async {
    final c = ProviderContainer(overrides: [
      playbackServiceProvider.overrideWithValue(synth),
      pieceMediaProvider.overrideWith((ref, id) async =>
          const [PieceMedia.synthesized, PieceMedia.silent]),
      renderedScoreEnabledProvider.overrideWith((_) => rendered),
      if (renderedService != null)
        renderedScoreServiceProvider.overrideWith((_) => renderedService),
    ]);
    addTearDown(c.dispose);
    c.read(selectedPieceProvider.notifier).state = piece;
    await c.read(pieceMediaProvider('p').future);
    return c;
  }

  test('live synth: picking Silent mutes it; picking Simulated unmutes it',
      () async {
    final synth = PlaybackService(MidiGenerator.forTest());
    final c = await containerFor(synth, rendered: false);

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

  test('rendered score: Silent is the same player, muted; the synth is left '
      'alone', () async {
    final synth = PlaybackService(MidiGenerator.forTest());
    final rendered = _QuietRendered();
    final c = await containerFor(synth,
        rendered: true, renderedService: rendered);

    final sub = c.listen(activePlaybackServiceProvider, (_, _) {});
    expect(c.read(activePlaybackServiceProvider), same(rendered));
    expect(rendered.muted, isFalse);

    c.read(selectedMediaIdProvider('p').notifier).state = 'silent';
    expect(c.read(activePlaybackServiceProvider), same(rendered));
    expect(rendered.muted, isTrue);
    expect(synth.muted, isFalse);

    c.read(selectedMediaIdProvider('p').notifier).state = 'synthesized';
    expect(c.read(activePlaybackServiceProvider), same(rendered));
    expect(rendered.muted, isFalse);
    expect(rendered.volumes, [0, 1]);
    sub.close();
  });
}

/// Records what the player would be told, with no player behind it.
class _QuietRendered extends RenderedScorePlaybackService {
  _QuietRendered() : super(MidiGenerator.forTest());
  final volumes = <double>[];
  @override
  void onMuteChanged(bool muted) => volumes.add(muted ? 0 : 1);
}
