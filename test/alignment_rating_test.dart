import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:score_sync/score_sync.dart';
import 'package:violin_practice_companion/services/media_alignment_store.dart';
import 'package:violin_practice_companion/services/piece_media_store.dart';
import 'package:violin_practice_companion/services/providers.dart';

void main() {
  final at = DateTime.utc(2026, 11, 17, 9, 30);
  PieceMedia recording({AlignmentRating? rating}) => PieceMedia(
        id: 'demo',
        label: 'Teacher demo',
        kind: MediaKind.recorded,
        alignmentKey: 'media:p1:demo',
        audio: const MediaRef.appFile('media/p1/demo/audio.wav'),
        analysis: const MediaRef.appFile('media/p1/demo/audio.wav'),
        alignmentRating: rating,
      );

  group('AlignmentRating', () {
    test('a bare Good is a whole rating, and round-trips', () {
      final good = AlignmentRating(verdict: AlignmentVerdict.good, ratedAt: at);
      expect(good.toJson(), {
        'verdict': 'good',
        'ratedAt': '2026-11-17T09:30:00.000Z',
      });
      expect(AlignmentRating.fromJson(good.toJson()), good);
    });

    test('off spans and the rated alignment round-trip', () {
      final off = AlignmentRating(
        verdict: AlignmentVerdict.bitOff,
        offSpans: const [(1, 12), (44, 44)],
        anchorsHash: '0badf00d',
        ratedAt: at,
      );
      expect(AlignmentRating.fromJson(off.toJson()), off);
      expect(off.spansLabel, 'bars 1–12 and 44');
    });

    test('labels one bar, and several spans', () {
      AlignmentRating r(List<(int, int)> s) => AlignmentRating(
          verdict: AlignmentVerdict.wrong, offSpans: s, ratedAt: at);
      expect(r(const [(7, 7)]).spansLabel, 'bar 7');
      expect(r(const [(1, 2), (5, 5), (9, 12)]).spansLabel,
          'bars 1–2, 5 and 9–12');
      expect(r(const []).spansLabel, '');
    });

    test('garbage reads as no rating', () {
      expect(AlignmentRating.fromJson({'verdict': 'meh', 'ratedAt': 'x'}),
          isNull);
      expect(AlignmentRating.fromJson('good'), isNull);
    });
  });

  group('PieceMedia carries its rating', () {
    final rating = AlignmentRating(
        verdict: AlignmentVerdict.wrong,
        offSpans: const [(3, 4)],
        ratedAt: at);

    test('through JSON; a row written before ratings reads as unrated', () {
      final rated = recording(rating: rating);
      expect(PieceMedia.fromJson(rated.toJson()), rated);
      expect(recording().toJson().containsKey('alignmentRating'), isFalse);
      expect(PieceMedia.fromJson(recording().toJson())!.alignmentRating,
          isNull);
    });

    test('through every copy, so editing a medium keeps it', () {
      final rated = recording(rating: rating);
      expect(rated.copyWith(label: 'x').alignmentRating, rating);
      expect(rated.withContentWindow(startSeconds: 2).alignmentRating, rating);
      expect(
          rated
              .withFileReplaced(const MediaRef.appFile('media/p1/demo/audio.wav'),
                  const MediaRef.appFile('media/p1/demo/small.wav'))
              .alignmentRating,
          rating);
      expect(rated.withAlignmentRating(null).alignmentRating, isNull);
    });
  });

  test('the fingerprint tells two alignments apart, and is stable', () {
    final a = anchorsFingerprint(const [(0.0, 1.0), (1500.0, 2.5)]);
    expect(anchorsFingerprint(const [(0.0, 1.0), (1500.0, 2.5)]), a);
    expect(anchorsFingerprint(const [(0.0, 1.0), (1500.0, 2.6)]),
        isNot(a));
    expect(a, matches(RegExp(r'^[0-9a-f]{8}$')));
  });

  test('rating a medium stores it and keeps the cached alignment', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final media = recording();
    await PieceMediaStore().add('p1', media);
    const alignment = MediaAlignment(
        anchors: [ScoreAudioAnchor(0, 1), ScoreAudioAnchor(1500, 2.5)],
        generationBpm: 80);
    await MediaAlignmentStore().save(media.alignmentKey, alignment);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final rating =
        AlignmentRating(verdict: AlignmentVerdict.good, ratedAt: at);
    await container
        .read(mediaActionsProvider)
        .rateAlignment('p1', media, rating);

    final stored = await PieceMediaStore().load('p1');
    expect(stored.single.alignmentRating, rating);
    expect(await MediaAlignmentStore().load(media.alignmentKey), isNotNull,
        reason: 'a rating judges the alignment; it must not throw it away');
  });
}
