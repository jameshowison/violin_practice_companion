import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece.dart';
import '../models/piece_media.dart';
import '../screens/record_teacher_demo_screen.dart';
import '../services/audio_score_auto_aligner.dart' show alignmentReviewMessage;
import '../services/media_import.dart';
import '../services/media_playback_service.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../services/teacher_recording_capture.dart';

/// The piece screen's bottom tray: one picker naming what is playing the
/// piece, and the transport for whatever that is.
///
/// This replaces three trays — `PlaybackControls` for the synthesized score,
/// `PlayAlongControls` for a bundled track, `TeacherDemoControls` for a
/// recorded demo — of which the last two were near-identical and the first was
/// reached by falling off the end of two mutually-exclusive mode booleans that
/// each call site had to keep exclusive by hand.
///
/// The synthesized score is an entry in the picker like any other. It is not
/// media in the sense of having a file, and its transport is genuinely
/// different (a tempo it can be asked to change, rather than a rate a fixed
/// recording is replayed at) — but from where the user stands it is one more
/// answer to "what should play this", and offering it anywhere other than
/// alongside the rest would be hiding the thing every piece can always do.
class MediaControls extends ConsumerStatefulWidget {
  final Piece piece;
  final List<PieceMedia> media;
  final PieceMedia selected;

  const MediaControls({
    super.key,
    required this.piece,
    required this.media,
    required this.selected,
  });

  @override
  ConsumerState<MediaControls> createState() => _MediaControlsState();
}

class _MediaControlsState extends ConsumerState<MediaControls> {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          _MediaPicker(
            piece: widget.piece,
            media: widget.media,
            selected: widget.selected,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: widget.selected.isSynthesized
                ? const _SynthesizedTransport()
                // Deliberately NOT keyed by media id: a fresh State per
                // medium would reset the playback speed every time the user
                // switched track, and slowing a passage down is a setting you
                // hold across takes. `didUpdateWidget` reloads instead.
                : _MediaTransport(
                    piece: widget.piece,
                    media: widget.selected,
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Picker ───────────────────────────────────────────────────────────────────

/// Names what is playing, and opens the list of everything that could.
///
/// A [PopupMenuButton] rather than a `DropdownButton` because the list is not
/// only a list: it ends with the two ways to add to it, and each removable
/// medium carries its own delete. A dropdown can hold rows like that but
/// cannot report which part of one was tapped.
class _MediaPicker extends ConsumerWidget {
  final Piece piece;
  final List<PieceMedia> media;
  final PieceMedia selected;

  const _MediaPicker({
    required this.piece,
    required this.media,
    required this.selected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canImport = const MediaImporter().isSupported;
    final canRecord = TeacherRecordingCapture().isSupported;

    return PopupMenuButton<_PickerAction>(
      tooltip: 'Choose what plays this piece',
      position: PopupMenuPosition.over,
      onSelected: (action) => _handle(context, ref, action),
      // `menuContext` is deliberately not named `context`: it belongs to the
      // popup route, which is about to be popped. The confirm dialog below is
      // itself a route and must be pushed from the picker's own context, which
      // outlives the menu — pushing from the menu's leaves the dialog without
      // a parent the moment the menu closes.
      itemBuilder: (menuContext) => [
        for (final m in media)
          PopupMenuItem(
            value: _PickerAction.select(m.id),
            child: _MediaRow(
              media: m,
              isSelected: m.id == selected.id,
              // Both actions pop the menu first and then run against the
              // picker's own context, for the reason given above.
              onEditWindow: m.isRemovable && m.canAlign
                  ? () {
                      Navigator.pop(menuContext);
                      _editContentWindow(context, ref, m);
                    }
                  : null,
              onDelete: m.isRemovable
                  ? () {
                      Navigator.pop(menuContext);
                      _confirmDelete(context, ref, m);
                    }
                  : null,
            ),
          ),
        if (canImport || canRecord) const PopupMenuDivider(),
        if (canImport)
          const PopupMenuItem(
            value: _PickerAction.import(),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(Icons.library_music),
              title: Text('Add audio or video…'),
            ),
          ),
        if (canRecord)
          const PopupMenuItem(
            value: _PickerAction.record(),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(Icons.videocam),
              title: Text('Record a demo…'),
            ),
          ),
      ],
      child: Container(
        constraints: const BoxConstraints(maxWidth: 132),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconFor(selected.kind), size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                selected.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _handle(
      BuildContext context, WidgetRef ref, _PickerAction action) async {
    switch (action.type) {
      case _PickerActionType.select:
        ref.read(selectedMediaIdProvider(piece.id).notifier).state = action.mediaId;
      case _PickerActionType.record:
        await Navigator.of(context).push(MaterialPageRoute<bool>(
          builder: (_) => RecordTeacherDemoScreen(piece: piece),
        ));
      case _PickerActionType.import:
        await _import(context, ref);
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final result = await const MediaImporter().pickAndImport(pieceId: piece.id);
    if (result.isCancelled || !context.mounted) return;
    final imported = result.media;
    if (imported == null) {
      _say(context, result.error ?? "That file couldn't be imported.");
      return;
    }
    await ref.read(pieceMediaStoreProvider).add(piece.id, imported);
    // Select it straight away: importing a file is a request to use it, and
    // leaving the user to then pick it out of a menu would be asking twice.
    ref.read(selectedMediaIdProvider(piece.id).notifier).state = imported.id;
    ref.invalidate(pieceMediaProvider(piece.id));
  }

  /// Asks where the tune sits inside a recording, and re-runs the alignment
  /// with the answer.
  ///
  /// Worth offering because the alternative — inferring it from the audio —
  /// cannot be made reliable: a lead-in that quotes the tune and a lead-in of
  /// hum pull the one constant that decides it in opposite directions (see
  /// docs/audio-sync-next-steps.md). The user has the answer for nothing; the
  /// aligner has to guess for it.
  Future<void> _editContentWindow(
      BuildContext context, WidgetRef ref, PieceMedia media) async {
    final window = await showDialog<_ContentWindow>(
      context: context,
      builder: (_) => _ContentWindowDialog(media: media),
    );
    if (window == null || !context.mounted) return;
    await ref.read(mediaActionsProvider).setContentWindow(
          piece.id,
          media,
          startSeconds: window.startSeconds,
          endSeconds: window.endSeconds,
        );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, PieceMedia media) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${media.label}"?'),
        content: Text(
          media.kind == MediaKind.recorded
              ? 'The recording and its alignment will be deleted from this '
                  'device. This cannot be undone.'
              : 'The imported copy and its alignment will be deleted from this '
                  'device. Your original file is not touched.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(mediaActionsProvider).deleteMedia(piece.id, media);
  }

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static IconData _iconFor(MediaKind kind) => switch (kind) {
        MediaKind.synthesized => Icons.piano,
        MediaKind.bundled => Icons.headphones,
        MediaKind.imported => Icons.library_music,
        MediaKind.recorded => Icons.school,
      };
}

class _MediaRow extends StatelessWidget {
  final PieceMedia media;
  final bool isSelected;
  final VoidCallback? onEditWindow;
  final VoidCallback? onDelete;

  const _MediaRow({
    required this.media,
    required this.isSelected,
    this.onEditWindow,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      // The popup menu sizes itself to its widest item and then rounds to a
      // 56pt step, and it is the LABEL that gives way when a row runs out of
      // room — raising the menu's own maxWidth does not move it (tried; the
      // menu stayed at the same 280pt). So the width is reclaimed here
      // instead: the leading icon's default 40pt slot and 16pt gap are more
      // than a 24pt glyph needs.
      minLeadingWidth: 24,
      horizontalTitleGap: 8,
      leading: Icon(
        isSelected ? Icons.check : _MediaPicker._iconFor(media.kind),
        color: isSelected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(media.label, overflow: TextOverflow.ellipsis),
      subtitle: _subtitle(),
      // Null rather than an empty Row for a medium with neither action —
      // bundled tracks and the synthesized score keep exactly the row they had.
      trailing: onEditWindow == null && onDelete == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onEditWindow != null)
                  _RowAction(
                    icon: Icons.content_cut,
                    tooltip: 'Where does the tune start?',
                    // Lit when this medium carries a window, so an alignment
                    // the user constrained is visibly not an inferred one.
                    highlighted: media.contentStartSeconds != null ||
                        media.contentEndSeconds != null,
                    onPressed: onEditWindow!,
                  ),
                if (onDelete != null)
                  _RowAction(
                    icon: Icons.delete_outline,
                    tooltip: 'Remove',
                    onPressed: onDelete!,
                  ),
              ],
            ),
    );
  }

  /// Names the content window when there is one, so a medium that is aligning
  /// against only part of its file says so — otherwise an alignment the user
  /// constrained months ago is indistinguishable from an inferred one.
  Widget? _subtitle() {
    // Window first: it is the part the user just set and may want to check,
    // where "with video" is static and the floating overlay announces itself.
    final parts = [
      ?_windowLabel(),
      if (media.video != null) 'with video',
    ];
    if (parts.isEmpty) return null;
    // Ellipsized like the title above it — two trailing buttons leave the text
    // column narrow inside the popup, so this has to be allowed to run out.
    return Text(parts.join(' · '),
        maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  String? _windowLabel() {
    final start = media.contentStartSeconds, end = media.contentEndSeconds;
    if (start == null && end == null) return null;
    String at(double s) => s.toStringAsFixed(1);
    if (end == null) return 'tune from ${at(start!)}s';
    if (start == null) return 'tune to ${at(end)}s';
    return 'tune ${at(start)}–${at(end)}s';
  }
}

/// One icon on a picker row.
///
/// Tighter than a bare [IconButton], whose 48pt minimum tap target is fine on
/// its own but puts two of them at 96pt inside a popup menu item that also has
/// to fit a label — which is what the row now holds.
class _RowAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool highlighted;
  final VoidCallback onPressed;

  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      color: highlighted ? Theme.of(context).colorScheme.primary : null,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: onPressed,
    );
  }
}

/// The answer to "where is the tune in this file", as typed. Either bound may
/// be null, meaning "infer that end as before" — this is additive to the DTW
/// open boundaries, not a replacement for them.
class _ContentWindow {
  final double? startSeconds;
  final double? endSeconds;

  const _ContentWindow(this.startSeconds, this.endSeconds);
}

/// Two seconds fields. Deliberately the plainest thing that can express the
/// idea: the scrub-and-mark this eventually wants belongs on the capture
/// screen, where there is a waveform to scrub, and is no use at all for a file
/// imported from elsewhere.
class _ContentWindowDialog extends StatefulWidget {
  final PieceMedia media;

  const _ContentWindowDialog({required this.media});

  @override
  State<_ContentWindowDialog> createState() => _ContentWindowDialogState();
}

class _ContentWindowDialogState extends State<_ContentWindowDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _start = TextEditingController(
      text: _format(widget.media.contentStartSeconds));
  late final _end =
      TextEditingController(text: _format(widget.media.contentEndSeconds));

  static String _format(double? seconds) =>
      seconds == null ? '' : seconds.toStringAsFixed(1);

  /// Null for an empty field — which is the "infer it" answer, not an error.
  static double? _parse(String raw) => double.tryParse(raw.trim());

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  String? _validate(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null) return 'Enter a number of seconds';
    if (value < 0) return "Can't be negative";
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final start = _parse(_start.text), end = _parse(_end.text);
    if (start != null && end != null && end <= start) {
      // Not a field-level error: neither figure is wrong on its own, it's the
      // pair that doesn't describe a span.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The tune has to end after it starts.')));
      return;
    }
    Navigator.of(context).pop(_ContentWindow(start, end));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Where is the tune?'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'If this recording has talking, tuning or a false start before '
              'the tune — or carries on afterwards — say so here and the score '
              'will be matched against just the music.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _start,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: _validate,
              decoration: const InputDecoration(
                labelText: 'Tune starts at',
                suffixText: 'seconds',
                helperText: 'Leave blank to work it out automatically',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _end,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: _validate,
              decoration: const InputDecoration(
                labelText: 'Tune ends at',
                suffixText: 'seconds',
                helperText: 'Leave blank for the end of the file',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Realign'),
        ),
      ],
    );
  }
}

enum _PickerActionType { select, import, record }

/// What a menu tap asked for. A small sealed-ish value rather than a nullable
/// media id, so "add" and "record" can't be confused with selecting a medium
/// that happens to be named the same thing.
class _PickerAction {
  final _PickerActionType type;
  final String? mediaId;

  const _PickerAction.select(String this.mediaId)
      : type = _PickerActionType.select;
  const _PickerAction.import()
      : type = _PickerActionType.import,
        mediaId = null;
  const _PickerAction.record()
      : type = _PickerActionType.record,
        mediaId = null;
}

// ── Transports ───────────────────────────────────────────────────────────────

/// The score played by the app's own soundfont engine: a tempo you set, a loop
/// you can leave on, and a count-off.
class _SynthesizedTransport extends ConsumerStatefulWidget {
  const _SynthesizedTransport();

  @override
  ConsumerState<_SynthesizedTransport> createState() =>
      _SynthesizedTransportState();
}

class _SynthesizedTransportState extends ConsumerState<_SynthesizedTransport> {
  double _tempo = 115.0;

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(playbackServiceProvider);
    final playState =
        ref.watch(playbackStateProvider).valueOrNull ?? PlaybackState.stopped;
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

    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          iconSize: 22,
          tooltip: 'Rewind',
          onPressed: () {
            service.stop();
            start();
          },
        ),
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
        IconButton(
          icon: const Icon(Icons.stop),
          iconSize: 22,
          tooltip: 'Stop',
          onPressed: service.stop,
        ),
        IconButton(
          icon: Icon(
            Icons.repeat,
            color: service.loopEnabled
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          iconSize: 22,
          tooltip: service.loopEnabled ? 'Loop on' : 'Loop off',
          onPressed: () =>
              setState(() => service.loopEnabled = !service.loopEnabled),
        ),
        const Icon(Icons.music_note, size: 16),
        const SizedBox(width: 2),
        Text('${_tempo.round()}',
            style:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
    );
  }
}

/// A real recording: play it, slow it down, re-run its alignment.
///
/// One transport for bundled tracks, imports and recordings alike — the three
/// differ in where their bytes came from and in nothing this widget touches.
class _MediaTransport extends ConsumerStatefulWidget {
  final Piece piece;
  final PieceMedia media;

  const _MediaTransport({required this.piece, required this.media});

  @override
  ConsumerState<_MediaTransport> createState() => _MediaTransportState();
}

class _MediaTransportState extends ConsumerState<_MediaTransport> {
  MediaLoadResult? _result;
  bool _loading = true;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant _MediaTransport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Value equality, not id equality: editing a medium's content window hands
    // this the same id with different alignment inputs, and the whole point of
    // the edit is that the alignment is re-run.
    if (oldWidget.media != widget.media) _load();
  }

  MediaPlaybackService get _service => ref.read(mediaPlaybackServiceProvider);

  Future<void> _load({bool realign = false}) async {
    setState(() => _loading = true);
    final parsed = await ref.read(parsedPieceProvider.future);
    if (parsed == null || !mounted) return;
    final result = realign
        ? await _service.realign(piece: parsed, media: widget.media)
        : await _service.load(piece: parsed, media: widget.media);
    // just_audio's playback rate is a player-level setting and is not reliably
    // preserved across loading a new source, so it is always reapplied.
    if (result.isPlayable) await _service.setPlaybackSpeed(_speed);
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final startMeasure = ref.watch(playbackStartMeasureProvider);
    final service = ref.watch(mediaPlaybackServiceProvider);

    return ValueListenableBuilder<bool>(
      valueListenable: service.isAligning,
      builder: (context, aligning, _) {
        if (aligning || _loading) {
          return Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(aligning ? 'Aligning…' : 'Loading…'),
            ],
          );
        }

        final result = _result;
        if (result != null && !result.isPlayable) {
          return _Problem(
            message: result.message ?? "This medium can't be played.",
            onRetry: () => _load(),
          );
        }

        return Row(
          children: [
            IconButton(
              icon: const Icon(Icons.play_arrow),
              iconSize: 26,
              tooltip: 'Play',
              onPressed: () => service.play(fromMeasure: startMeasure),
            ),
            IconButton(
              icon: const Icon(Icons.pause),
              iconSize: 22,
              tooltip: 'Pause',
              onPressed: service.pause,
            ),
            // Speed scales the real playback rate via just_audio's setSpeed.
            // Safe to change at any time: the highlight clock reads the
            // player's file-time position, which stays correct regardless of
            // rate — only how fast real time advances through it changes,
            // which is exactly what slowing down a hard passage should do.
            const Icon(Icons.speed, size: 16),
            const SizedBox(width: 2),
            Text('${_speed.toStringAsFixed(2)}x',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold)),
            Expanded(
              child: Slider(
                value: _speed,
                min: 0.5,
                max: 1.5,
                divisions: 20,
                label: '${_speed.toStringAsFixed(2)}x',
                onChanged: (v) => setState(() => _speed = v),
                onChangeEnd: (v) {
                  _speed = v;
                  service.setPlaybackSpeed(v);
                },
              ),
            ),
            // Only offered where it can do something: a medium with no
            // analysis source has nothing to re-run.
            if (widget.media.canAlign)
              IconButton(
                icon: const Icon(Icons.tune),
                iconSize: 20,
                tooltip: 'Realign to the score',
                onPressed: () => _load(realign: true),
              ),
            if (result?.outcome == MediaLoadOutcome.playsWithoutHighlight)
              IconButton(
                icon: const Icon(Icons.info_outline, color: Colors.amber),
                iconSize: 20,
                tooltip: "The score won't follow this — tap for details",
                onPressed: () => _say(result!.message!),
              ),
            ValueListenableBuilder<bool>(
              valueListenable: service.alignmentLooksUncertain,
              builder: (context, uncertain, _) => uncertain
                  ? IconButton(
                      icon: const Icon(Icons.warning_amber, color: Colors.amber),
                      iconSize: 20,
                      tooltip: 'Alignment may be off — tap for details',
                      onPressed: () => _say(alignmentReviewMessage),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Shown in place of the transport when the selected medium can't be played at
/// all — a missing file, or one the player refused.
class _Problem extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _Problem({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.error_outline, size: 18, color: Colors.redAccent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
