import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece_media.dart';
import '../services/providers.dart';
import '../ui/adaptive/adaptive.dart';

/// Rating how well a recording's alignment followed it: a verdict from the
/// media picker ([rateAlignment]), bars marked from the selection
/// ([markAlignmentOff]). Both store an [AlignmentRating] on the medium, which
/// the dev library carries to `scripts/alignment_diff.py`.
///
/// Nothing is sent anywhere. A tester tells us by screenshot, which TestFlight
/// offers to send: so each rating ends with a snackbar that states it in
/// words a screenshot can carry.

/// The alignment currently loaded for [media], fingerprinted, or null when
/// the playback service holds another medium (or none).
String? _loadedAnchorsHash(WidgetRef ref, PieceMedia media) {
  final service = ref.read(mediaPlaybackServiceProvider);
  if (service.media?.id != media.id || service.anchors.isEmpty) return null;
  return anchorsFingerprint(
      [for (final a in service.anchors) (a.scoreMs, a.audioSec)]);
}

/// Whether [rating] judged an alignment other than the one now loaded.
bool ratedBeforeRealign(WidgetRef ref, PieceMedia media) {
  final rating = media.alignmentRating;
  if (rating?.anchorsHash == null) return false;
  final now = _loadedAnchorsHash(ref, media);
  return now != null && now != rating!.anchorsHash;
}

/// One line describing [media]'s rating, for the picker row's subtitle.
/// Short, bars first after the verdict: the picker is ~280pt wide on a
/// compact phone and this truncates, and the bars are the useful part.
String? ratingSummary(PieceMedia media, {bool stale = false}) {
  final r = media.alignmentRating;
  if (r == null) return null;
  final spans = r.spansLabel;
  return '${r.verdictLabel}${spans.isEmpty ? '' : ': $spans'}'
      '${stale ? ' (before realign)' : ''}';
}

enum _Choice { good, bitOff, wrong, clear }

/// Asks how well [media] followed, and stores the answer.
Future<void> rateAlignment(BuildContext context, WidgetRef ref, String pieceId,
    PieceMedia media) async {
  final current = media.alignmentRating;
  final choice = await showAppActionSheet<_Choice>(
    context,
    title: 'How well did the highlight follow "${media.label}"?',
    actions: [
      const AppSheetAction(
          value: _Choice.good, label: 'Good', icon: Icons.thumb_up_outlined),
      const AppSheetAction(
          value: _Choice.bitOff,
          label: 'A bit off',
          icon: Icons.thumbs_up_down_outlined),
      const AppSheetAction(
          value: _Choice.wrong, label: 'Wrong', icon: Icons.thumb_down_outlined),
      if (current != null)
        const AppSheetAction(
            value: _Choice.clear,
            label: 'Clear rating',
            icon: Icons.clear,
            destructive: true),
    ],
  );
  if (choice == null || !context.mounted) return;
  final rating = switch (choice) {
    _Choice.clear => null,
    _ => AlignmentRating(
        verdict: switch (choice) {
          _Choice.good => AlignmentVerdict.good,
          _Choice.bitOff => AlignmentVerdict.bitOff,
          _ => AlignmentVerdict.wrong,
        },
        // Good and "off at bars …" contradict each other; any other verdict
        // keeps the bars already marked.
        offSpans:
            choice == _Choice.good ? const [] : current?.offSpans ?? const [],
        anchorsHash: _loadedAnchorsHash(ref, media),
        ratedAt: DateTime.now(),
      ),
  };
  await ref.read(mediaActionsProvider).rateAlignment(pieceId, media, rating);
  if (!context.mounted) return;
  _confirm(context, media, rating);
}

/// Adds bars [start]–[end] (measure numbers) to [media]'s off spans. A
/// recording with bars marked off is at least "a bit off".
Future<void> markAlignmentOff(BuildContext context, WidgetRef ref,
    String pieceId, PieceMedia media, int start, int end) async {
  final current = media.alignmentRating;
  final spans = [
    ...?current?.offSpans,
    if (!(current?.offSpans.contains((start, end)) ?? false)) (start, end),
  ];
  final verdict = current == null || current.verdict == AlignmentVerdict.good
      ? AlignmentVerdict.bitOff
      : current.verdict;
  final rating = AlignmentRating(
    verdict: verdict,
    offSpans: spans,
    anchorsHash: _loadedAnchorsHash(ref, media),
    ratedAt: DateTime.now(),
  );
  await ref.read(mediaActionsProvider).rateAlignment(pieceId, media, rating);
  if (!context.mounted) return;
  _confirm(context, media, rating);
}

void _confirm(BuildContext context, PieceMedia media, AlignmentRating? r) {
  final what = r == null
      ? 'Rating cleared for "${media.label}".'
      : '"${media.label}": ${r.verdictLabel}'
          '${r.offSpans.isEmpty ? '' : ', off at ${r.spansLabel}'}. '
          'To tell us, take a screenshot now; TestFlight will offer to send '
          'it.';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        // Long enough to take the screenshot, but it covers the transport.
        content: Text(what), duration: const Duration(seconds: 5)));
}
