import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/parsed_piece.dart';
import 'media_playback_service.dart';
import 'playback_service_base.dart';
import 'rendered_score_cache.dart';

/// The synthesized score, played as a recording: rendered to a file at one of
/// three tempos and played through [MediaPlaybackService]'s player, so it
/// gets the same speaker compensation, route following, clip end and count-in
/// as a recording (docs/rendered-score-plan.md).
///
/// A tempo is the nearest render played at a rate: within a render's band a
/// change is just a rate change, mid-play; into another band it loads that
/// render and starts again at the bar being played, as the live synth's
/// [setTempo] does.
class RenderedScorePlaybackService extends MediaPlaybackService {
  RenderedScorePlaybackService(
    super.generator, {
    RenderedScoreCache? cache,
    super.heardDelay,
  }) : _cache = cache ?? RenderedScoreCache();

  final RenderedScoreCache _cache;

  /// The renders, as shares of the performance tempo P: each covers a band a
  /// factor of 1.26 wide, so 60–120% of P plays within ±12% of a render.
  static const renderFactors = [0.67, 0.85, 1.07];

  /// The three render tempos for a performance tempo of [performanceBpm].
  static List<int> renderTempos(double performanceBpm) => [
        for (final f in renderFactors) math.max(1, (performanceBpm * f).round()),
      ];

  /// The render nearest [bpm] by ratio, which is what keeps the stretch
  /// smallest.
  static int nearestRender(List<int> renders, int bpm) {
    var best = renders.first;
    for (final r in renders) {
      if ((math.log(bpm / r)).abs() < (math.log(bpm / best)).abs()) best = r;
    }
    return best;
  }

  /// True while the render for the current tempo is being made (or read).
  final ValueNotifier<bool> isRendering = ValueNotifier(false);

  /// Null until the first render has loaded; then the render tempo playing.
  final ValueNotifier<int?> loadedRender = ValueNotifier(null);

  ParsedPiece? _piece;
  double? _performance;
  int _target = 0;
  int _request = 0;

  /// The tempo asked for, in quarter-note bpm — not [currentBpm], which is
  /// the render's (the timeline the anchors are in).
  int get targetBpm => _target;

  /// Plays [piece] at [bpm], with renders made around [performanceBpm].
  /// Called on every change of any of them; a change within the loaded
  /// render's band costs only a rate change.
  Future<void> configure({
    required ParsedPiece piece,
    required double performanceBpm,
    required int bpm,
  }) async {
    final same = identical(piece, _piece) && performanceBpm == _performance;
    _piece = piece;
    _performance = performanceBpm;
    _target = bpm;
    final renders = renderTempos(performanceBpm);
    final render = nearestRender(renders, bpm);
    debugPrint('[rendered] $bpm bpm: render $render of $renders'
        '${same && render == loadedRender.value ? ' (rate only)' : ''}');
    if (same && render == loadedRender.value) {
      await setPlaybackSpeed(bpm / render);
      return;
    }
    final request = ++_request;
    final resume =
        playbackState == PlaybackState.playing ? resumePoint() : null;
    isRendering.value = true;
    try {
      await generator.init();
      final file =
          await _cache.obtain(piece, generator.generate(piece, render), render);
      if (request != _request) return;
      if (file == null) {
        debugPrint('[rendered] no render at $render bpm; nothing to play');
        return;
      }
      final result = await loadAligned(
        piece: piece,
        file: file.path,
        anchors: file.anchors,
        generationBpm: render,
      );
      if (request != _request) return;
      loadedRender.value = result.isPlayable ? render : null;
      await setPlaybackSpeed(_target / render);
      if (resume != null && result.isPlayable) resumeAt(resume);
    } finally {
      if (request == _request) isRendering.value = false;
    }
    // The other two, one at a time, so they don't compete with what plays.
    if (request == _request) {
      unawaited(() async {
        for (final r in renders) {
          if (r == render || request != _request) continue;
          await _cache.obtain(piece, generator.generate(piece, r), r);
        }
      }());
    }
  }

  /// The intro is the woodblock count, so with the count-in off a play from
  /// the top starts on the first bar.
  @override
  bool get playsIntroWithoutCount => false;

  /// Not the base class's regeneration, which would move the timeline out
  /// from under the anchors: a tempo is a render and a rate.
  @override
  void setTempo(int bpm) {
    final piece = _piece, performance = _performance;
    if (piece == null || performance == null) return;
    unawaited(configure(piece: piece, performanceBpm: performance, bpm: bpm));
  }

  @override
  void dispose() {
    _request++;
    isRendering.dispose();
    loadedRender.dispose();
    super.dispose();
  }
}
