import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_track_variant.dart';
import '../models/piece.dart';
import '../services/audio_sync_playback_service.dart';
import '../services/providers.dart';

/// The bottom tray shown instead of `PlaybackControls` while Play Along mode
/// is active: pick a track, play/pause it, or force a re-alignment. Owns none
/// of the audio-sync clock itself — [service] is created once per
/// piece-detail visit by the screen (via `audioSyncServiceProvider`) and
/// shared with the staff view, so both read the same
/// `currentHighlightNotifier`.
///
/// Calibration is automatic (see [AudioScoreAutoAligner]) — there is no
/// tap-along step or calibration screen; the only visible state while a
/// piece/track is aligning for the first time is the "Aligning…" indicator.
class PlayAlongControls extends ConsumerStatefulWidget {
  final Piece piece;
  final String audioFolder;
  final AudioSyncPlaybackService service;

  const PlayAlongControls({
    super.key,
    required this.piece,
    required this.audioFolder,
    required this.service,
  });

  @override
  ConsumerState<PlayAlongControls> createState() => _PlayAlongControlsState();
}

class _PlayAlongControlsState extends ConsumerState<PlayAlongControls> {
  bool _ready = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTrack(ref.read(selectedAudioTrackProvider));
    });
  }

  Future<void> _loadTrack(AudioTrackVariant track) async {
    setState(() => _ready = false);
    final parsed = await ref.read(parsedPieceProvider.future);
    if (parsed == null || !mounted) return;
    await widget.service.load(
      piece: parsed,
      pieceId: widget.piece.id,
      audioFolder: widget.audioFolder,
      track: track,
    );
    // just_audio's playback rate is a player-level setting, not reliably
    // preserved across setAsset, so always reapply the tray's current speed
    // after loading.
    await widget.service.setPlaybackSpeed(_speed);
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _realign(AudioTrackVariant track) async {
    setState(() => _ready = false);
    final parsed = await ref.read(parsedPieceProvider.future);
    if (parsed == null || !mounted) return;
    await widget.service.realign(
      piece: parsed,
      pieceId: widget.piece.id,
      audioFolder: widget.audioFolder,
      track: track,
    );
    await widget.service.setPlaybackSpeed(_speed);
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(selectedAudioTrackProvider);
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
              DropdownButton<AudioTrackVariant>(
                value: track,
                items: [
                  for (final v in AudioTrackVariant.values)
                    DropdownMenuItem(value: v, child: Text(v.label)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  ref.read(selectedAudioTrackProvider.notifier).state = v;
                  _loadTrack(v);
                },
              ),
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
              // Speed control — scales real playback rate via just_audio's
              // setSpeed. Safe to change any time: the audio-sync clock
              // reads the player's file-time position directly, which stays
              // correct regardless of rate — only how fast real time
              // advances through it changes, which is exactly what slowing
              // down a hard passage should do.
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
                onPressed: () => _realign(track),
              ),
            ],
          );
        },
      ),
    );
  }
}
