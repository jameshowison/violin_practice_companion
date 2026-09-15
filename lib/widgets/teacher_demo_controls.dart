import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece.dart';
import '../services/audio_score_auto_aligner.dart' show alignmentReviewMessage;
import '../services/providers.dart';
import '../services/teacher_recording_playback_service.dart';

/// The bottom tray shown instead of `PlaybackControls`/`PlayAlongControls`
/// while teacher-demo mode is active. Mirrors `PlayAlongControls`'s shape
/// (play/pause, speed, realign, uncertainty warning) but with no track
/// picker — a teacher recording is always one take, not three mixes of the
/// same session — and no calibration step: alignment already ran once, right
/// after recording (see RecordTeacherDemoScreen); "Realign" here only reruns
/// DTW against the current score, for when the score itself changes later.
class TeacherDemoControls extends ConsumerStatefulWidget {
  final Piece piece;
  final TeacherRecordingPlaybackService service;

  const TeacherDemoControls({
    super.key,
    required this.piece,
    required this.service,
  });

  @override
  ConsumerState<TeacherDemoControls> createState() =>
      _TeacherDemoControlsState();
}

class _TeacherDemoControlsState extends ConsumerState<TeacherDemoControls> {
  bool _ready = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _ready = false);
    final parsed = await ref.read(parsedPieceProvider.future);
    if (parsed == null || !mounted) return;
    final loaded =
        await widget.service.load(piece: parsed, pieceId: widget.piece.id);
    if (loaded) await widget.service.setPlaybackSpeed(_speed);
    if (mounted) setState(() => _ready = loaded);
  }

  Future<void> _realign() async {
    setState(() => _ready = false);
    final parsed = await ref.read(parsedPieceProvider.future);
    if (parsed == null || !mounted) return;
    await widget.service.realign(piece: parsed, pieceId: widget.piece.id);
    await widget.service.setPlaybackSpeed(_speed);
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    final startMeasure = ref.watch(playbackStartMeasureProvider);
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.service.isAligning,
        builder: (context, aligning, _) {
          if (aligning) {
            return const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Aligning…'),
              ],
            );
          }
          return Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: 'Play',
                onPressed: _ready
                    ? () => widget.service.play(fromMeasure: startMeasure)
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.pause),
                tooltip: 'Pause',
                onPressed: _ready ? widget.service.pause : null,
              ),
              const Icon(Icons.speed, size: 16),
              Text(
                '${_speed.toStringAsFixed(2)}x',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              SizedBox(
                width: 160,
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 1.5,
                  divisions: 20,
                  label: '${_speed.toStringAsFixed(2)}x',
                  onChanged: (v) => setState(() => _speed = v),
                  onChangeEnd: (v) {
                    _speed = v;
                    widget.service.setPlaybackSpeed(v);
                  },
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text('Realign'),
                onPressed: _realign,
              ),
              ValueListenableBuilder<bool>(
                valueListenable: widget.service.alignmentLooksUncertain,
                builder: (context, uncertain, _) => uncertain
                    ? IconButton(
                        icon: const Icon(Icons.warning_amber,
                            color: Colors.amber),
                        tooltip: 'Alignment may be off — tap for details',
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(alignmentReviewMessage)),
                          );
                        },
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }
}
