import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';

class PlaybackControls extends ConsumerStatefulWidget {
  const PlaybackControls({super.key});

  @override
  ConsumerState<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends ConsumerState<PlaybackControls> {
  double _tempo = 115.0;

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(playbackServiceProvider);
    final stateAsync = ref.watch(playbackStateProvider);
    final playState = stateAsync.valueOrNull ?? PlaybackState.stopped;
    final selection = ref.watch(measureSelectionProvider);
    final isPlaying = playState == PlaybackState.playing;

    // The service is handed a ready-made count-off and a plain measure number;
    // the meter, the minimum and the pickup are all resolved in the providers,
    // which is what keeps this button and the drawer's readout in agreement.
    final countIn = ref.watch(resolvedCountInProvider);
    final startMeasure = ref.watch(playbackStartMeasureProvider);

    void start() => service.play(
          fromMeasure: startMeasure,
          toMeasure: selection?.endMeasure,
          countIn: countIn,
        );

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
          children: [
            // Rewind
            IconButton(
              icon: const Icon(Icons.skip_previous),
              iconSize: 22,
              tooltip: 'Rewind',
              onPressed: () {
                service.stop();
                start();
              },
            ),
            // Play / Pause
            IconButton(
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
              iconSize: 26,
              tooltip: isPlaying ? 'Pause' : 'Play',
              onPressed: () {
                if (isPlaying) {
                  service.pause();
                } else {
                  // Paused and stopped both resume with a fresh count-off: the
                  // instrument has come down either way.
                  start();
                }
              },
            ),
            // Stop
            IconButton(
              icon: const Icon(Icons.stop),
              iconSize: 22,
              tooltip: 'Stop',
              onPressed: service.stop,
            ),
            // Loop toggle
            IconButton(
              icon: Icon(
                Icons.repeat,
                color: service.loopEnabled
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              iconSize: 22,
              tooltip: service.loopEnabled ? 'Loop on' : 'Loop off',
              onPressed: () {
                setState(() => service.loopEnabled = !service.loopEnabled);
              },
            ),
            // Tempo label
            const Icon(Icons.music_note, size: 16),
            const SizedBox(width: 2),
            Text(
              '${_tempo.round()}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            // Tempo slider
            Expanded(
              child: Slider(
                value: _tempo,
                min: 40,
                max: 200,
                divisions: 160,
                label: '${_tempo.round()} BPM',
                onChanged: (v) => setState(() => _tempo = v),
                onChangeEnd: (v) {
                  _tempo = v;
                  service.setTempo(v.round());
                },
              ),
            ),
          ],
      ),
    );
  }
}
