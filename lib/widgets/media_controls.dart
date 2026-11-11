import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/piece.dart';
import '../models/piece_media.dart';
import '../screens/record_teacher_demo_screen.dart';
import '../services/audio_output.dart';
import '../services/audio_score_auto_aligner.dart' show alignmentReviewMessage;
import '../services/media_import.dart';
import '../services/media_playback_service.dart';
import '../services/playback_service_base.dart';
import '../services/providers.dart';
import '../services/sync_calibration.dart' show CalibrationResult;
import '../services/sync_calibrator.dart';
import '../services/teacher_recording_capture.dart';
import 'tempo_controls.dart';

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
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      // A phone held upright can't fit the picker's name, four 48pt buttons
      // and a usable slider: on the iPhone SE (375pt) the slider was left
      // 15pt and couldn't move. Narrow, the picker drops to its kind icon (the
      // name is in its tooltip and its menu) and the buttons go compact,
      // which hands the slider ~100pt back.
      child: LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 440;
        // The default inactive track all but vanishes against this bar's
        // background, so you couldn't see how much range was left; outline
        // is the scheme's own "visible but secondary" grey.
        final sliders = theme.sliderTheme.copyWith(
            inactiveTrackColor: theme.colorScheme.outline,
            activeTickMarkColor: Colors.transparent,
            inactiveTickMarkColor: Colors.transparent);
        return Theme(
          data: narrow
              // Density alone leaves each button padded back out to a 48pt
              // tap target; shrink-wrapping lets it come down to 40.
              ? theme.copyWith(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  sliderTheme: sliders)
              : theme.copyWith(sliderTheme: sliders),
          child: Row(
            children: [
              _MediaPicker(
                piece: widget.piece,
                media: widget.media,
                selected: widget.selected,
                iconOnly: narrow,
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
      }),
    );
  }
}

/// The id of a medium whose alignment the menu has asked to be re-run, until
/// the transport playing it takes the request.
final _pendingRealignProvider = StateProvider<String?>((_) => null);

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

  /// Show only the kind icon, not the name — for a bar too narrow for both.
  final bool iconOnly;

  const _MediaPicker({
    required this.piece,
    required this.media,
    required this.selected,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canImport = const MediaImporter().isSupported;
    final canRecord = TeacherRecordingCapture().isSupported;

    return PopupMenuButton<_PickerAction>(
      tooltip: iconOnly
          ? 'Playing: ${selected.label}'
          : 'Choose what plays this piece',
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
              onRealign: m.canAlign
                  ? () {
                      Navigator.pop(menuContext);
                      _realign(context, ref, m);
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
            if (!iconOnly) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  selected.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
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

  /// Re-runs a medium's alignment, first asking — where the medium can keep
  /// one — where the tune sits inside the file.
  ///
  /// The window is worth offering because the alternative — inferring it from the audio —
  /// cannot be made reliable: a lead-in that quotes the tune and a lead-in of
  /// hum pull the one constant that decides it in opposite directions (see
  /// docs/audio-sync-next-steps.md). The user has the answer for nothing; the
  /// aligner has to guess for it.
  Future<void> _realign(
      BuildContext context, WidgetRef ref, PieceMedia media) async {
    final window = await showDialog<_ContentWindow>(
      context: context,
      builder: (_) => _RealignDialog(media: media),
    );
    if (window == null || !context.mounted) return;
    final changed = media.isRemovable &&
        (window.startSeconds != media.contentStartSeconds ||
            window.endSeconds != media.contentEndSeconds);
    if (changed) {
      // New alignment inputs: the transport sees a different medium and
      // re-runs the alignment itself (see _MediaTransport.didUpdateWidget).
      await ref.read(mediaActionsProvider).setContentWindow(
            piece.id,
            media,
            startSeconds: window.startSeconds,
            endSeconds: window.endSeconds,
          );
    } else {
      // Same inputs, so the cached alignment would just be reused: ask the
      // transport to throw it away. Set before selecting, so a transport that
      // is only now switching to this medium finds the request waiting.
      ref.read(_pendingRealignProvider.notifier).state = media.id;
    }
    if (!context.mounted) return;
    // Realigning is something you watch happen, so it plays what you asked about.
    ref.read(selectedMediaIdProvider(piece.id).notifier).state = media.id;
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
  final VoidCallback? onRealign;
  final VoidCallback? onDelete;

  const _MediaRow({
    required this.media,
    required this.isSelected,
    this.onRealign,
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
      trailing: onRealign == null && onDelete == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onRealign != null)
                  _RowAction(
                    icon: Icons.tune,
                    tooltip: 'Realign to the score',
                    // Lit when this medium carries a window, so an alignment
                    // the user constrained is visibly not an inferred one.
                    highlighted: media.contentStartSeconds != null ||
                        media.contentEndSeconds != null,
                    onPressed: onRealign!,
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

/// Confirms a realign. For a medium that can keep a content window (the
/// user's own recordings and imports), also two seconds fields saying where the
/// tune is. The fields are deliberately the plainest thing that can express the
/// idea: the scrub-and-mark this eventually wants belongs on the capture
/// screen, where there is a waveform to scrub, and is no use at all for a file
/// imported from elsewhere.
class _RealignDialog extends StatefulWidget {
  final PieceMedia media;

  const _RealignDialog({required this.media});

  @override
  State<_RealignDialog> createState() => _RealignDialogState();
}

class _RealignDialogState extends State<_RealignDialog> {
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
    if (!widget.media.isRemovable) {
      Navigator.of(context).pop(const _ContentWindow(null, null));
      return;
    }
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
      title: const Text('Realign to the score?'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'This re-runs the sync between this recording and the score, '
                'replacing the current one. Worth doing if the score has been '
                'edited or the highlight drifts from the music.'),
            if (widget.media.isRemovable) ...[
            const SizedBox(height: 12),
            const Text(
              'If this recording has talking, tuning or a false start before '
              'the tune — or carries on afterwards — say so here and the score '
              'will be matched against just the music.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _start,
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

/// Play, from either transport: the practice selection's start and end — its
/// mid-bar edges and its repeat pass included — and the resolved count-off.
///
/// One function because the two transports used to build this argument list
/// each for themselves, and the recording's dropped the end: Play started at
/// the selected bar and ran on to the end of the piece. The meter, minimum and
/// pickup behind the count are resolved in the providers, which keeps this and
/// the drawer's readout in agreement. Read at the tap, not watched.
void _playSelection(WidgetRef ref, PlaybackServiceBase service) {
  final selection = ref.read(measureSelectionProvider);
  service.play(
    fromMeasure: ref.read(playbackStartMeasureProvider),
    fromNote: ref.read(playbackStartNoteProvider),
    toMeasure: selection?.endMeasure,
    toNote: selection?.endNote ?? -1,
    fromIndex: selection?.startPerf ?? -1,
    toIndex: selection?.endPerf ?? -1,
    countIn: ref.read(resolvedCountInProvider),
  );
}

/// Repeat the selection (or the piece) until stopped. One setting shared by
/// every source — see [loopEnabledProvider].
class _LoopButton extends ConsumerWidget {
  const _LoopButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(loopEnabledProvider);
    return IconButton(
      icon: Icon(Icons.repeat,
          color: on ? Theme.of(context).colorScheme.primary : null),
      iconSize: 22,
      tooltip: on ? 'Loop on' : 'Loop off',
      onPressed: () => ref.read(loopEnabledProvider.notifier).state = !on,
    );
  }
}

/// The score played by the app's own soundfont engine: a tempo you set, a loop
/// you can leave on, and a count-off.
class _SynthesizedTransport extends ConsumerStatefulWidget {
  const _SynthesizedTransport();

  @override
  ConsumerState<_SynthesizedTransport> createState() =>
      _SynthesizedTransportState();
}

class _SynthesizedTransportState extends ConsumerState<_SynthesizedTransport> {
  @override
  Widget build(BuildContext context) {
    final service = ref.watch(playbackServiceProvider);
    final playState =
        ref.watch(playbackStateProvider).valueOrNull ?? PlaybackState.stopped;
    final isPlaying = playState == PlaybackState.playing;

    return Row(
      children: [
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
              _playSelection(ref, service);
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.stop),
          iconSize: 22,
          tooltip: 'Stop',
          onPressed: service.stop,
        ),
        const _LoopButton(),
        IconButton(
          icon: Icon(
            service.muted ? Icons.volume_off : Icons.volume_up,
            color: service.muted ? Theme.of(context).colorScheme.primary : null,
          ),
          iconSize: 22,
          tooltip: service.muted ? 'Unmute' : 'Mute',
          onPressed: () => setState(() => service.muted = !service.muted),
        ),
        const _OutputPickerButton(
            source: AudioSyncSource.score, compact: true),
        // Named practice speeds rather than a slider: a slider's exact value
        // is hard to hit again tomorrow, and "slow / medium / performance" is
        // how the tempo is actually thought about. The bpm behind each name is
        // a drawer setting; the service is told in PieceDetailScreen.
        const Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TempoPresetPicker(),
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

  /// The rate that plays this recording at the tray's selected tempo — the
  /// same Slow / Medium / Performance bpm as the synthesized score, so a preset
  /// means one tempo whichever source is playing. With no tempo set for the
  /// piece, Performance is this recording's own tempo, i.e. exactly 1.0x.
  double get _speed => MediaPlaybackService.speedFor(
      ref.read(exactTempoBpmProvider), _service.recordingBpm);

  late final StateController<double?> _loadedBpm =
      ref.read(loadedRecordingBpmProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    // Back to the synthesized score (or off the screen): no recording's tempo
    // stands in for the piece's any more. A microtask, since a provider can't
    // be changed while the tree is being torn down.
    final loaded = _loadedBpm;
    Future.microtask(() => loaded.state = null);
    super.dispose();
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

  Future<void> _load() async {
    setState(() => _loading = true);
    final parsed = await ref.read(parsedPieceProvider.future);
    if (parsed == null || !mounted) return;
    // Asked for from the picker's menu. Consumed here, after the await, since
    // _load can start inside didUpdateWidget, where a provider can't be set.
    final realign = ref.read(_pendingRealignProvider) == widget.media.id;
    if (realign) ref.read(_pendingRealignProvider.notifier).state = null;
    final result = realign
        ? await _service.realign(piece: parsed, media: widget.media)
        : await _service.load(piece: parsed, media: widget.media);
    if (!mounted) return;
    _loadedBpm.state = result.isPlayable ? _service.recordingBpm : null;
    // The alignment cache may have just been written (first load) or redone.
    ref.invalidate(pieceRecordingBpmProvider(widget.piece.id));
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
    final service = ref.watch(mediaPlaybackServiceProvider);
    // A new preset (or new bpm behind one) re-rates the recording at once.
    // Safe mid-play: the highlight reads the player's file-time position.
    ref.listen(exactTempoBpmProvider, (_, _) {
      if (_result?.isPlayable ?? false) service.setPlaybackSpeed(_speed);
    });
    // A realign of the medium already playing; one that is being switched to
    // is picked up by the _load the switch itself runs.
    ref.listen(_pendingRealignProvider, (_, id) {
      if (id == widget.media.id) _load();
    });

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
            // One button that is whichever of Play and Pause makes sense now,
            // as on the synthesized transport — two side by side cost the
            // phone's play bar 40pt of slider.
            StreamBuilder<PlaybackState>(
              stream: service.state,
              initialData: service.playbackState,
              builder: (context, snap) {
                final isPlaying = snap.data == PlaybackState.playing;
                return IconButton(
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                  iconSize: 26,
                  tooltip: isPlaying ? 'Pause' : 'Play',
                  // Counted in like the synthesized score: back from the
                  // entry at the recording's own tempo (see
                  // MediaPlaybackService.recordingLeadIn). An unaligned
                  // recording ignores the count — it has no entry to land on.
                  onPressed: isPlaying
                      ? service.pause
                      : () {
                          service.leadInMode =
                              ref.read(recordingLeadInProvider);
                          _playSelection(ref, service);
                        },
                );
              },
            ),
            // Repeats the selection, as on the synthesized transport. An
            // unaligned recording has no bars to loop and plays to its end.
            const _LoopButton(),
            // The same tempo picker as the synthesized transport. A recording
            // can't be re-generated at a bpm, so the chosen bpm becomes a
            // playback rate against the recording's own measured tempo (see
            // MediaPlaybackService.speedFor); the rate is shown beside it.
            // Flexible, not Expanded: the row is left-justified, so the
            // buttons after it follow the rate rather than sit in the corner.
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Flexible(child: TempoPresetPicker()),
                  Consumer(builder: (context, ref, _) {
                    ref.watch(exactTempoBpmProvider);
                    final recBpm = service.recordingBpm;
                    return Tooltip(
                      message: recBpm == null
                          ? "This recording isn't matched to the score, so it "
                              'plays at its own speed.'
                          : 'This recording ≈ ${recBpm.round()} bpm',
                      child: Text('${_speed.toStringAsFixed(2)}×',
                          style: Theme.of(context).textTheme.bodySmall),
                    );
                  }),
                ],
              ),
            ),
            const _OutputPickerButton(source: AudioSyncSource.recording),
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

/// Opens the audio output sheet: which speaker, a button for the system
/// speaker / Bluetooth / AirPlay picker, and the sync fine-tune for this
/// speaker. Hidden where there is no native picker (see
/// [AudioOutput.canPick]). Tinted when the sound is going somewhere other than
/// the built-in speaker, so that is visible at a glance.
class _OutputPickerButton extends StatefulWidget {
  /// The score transport's row is already full on a 375pt phone.
  final bool compact;

  /// Which player's sync the sheet's slider tunes.
  final AudioSyncSource source;

  const _OutputPickerButton({required this.source, this.compact = false});

  @override
  State<_OutputPickerButton> createState() => _OutputPickerButtonState();
}

class _OutputPickerButtonState extends State<_OutputPickerButton> {
  @override
  void initState() {
    super.initState();
    AudioOutput.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AudioOutputRoute?>(
      valueListenable: AudioOutput.route,
      builder: (context, route, _) {
        if (route == null) return const SizedBox.shrink();
        final elsewhere = route.portType != 'Speaker';
        return IconButton(
          key: const ValueKey('audio_output_picker'),
          icon: const Icon(Icons.airplay),
          iconSize: 20,
          color: elsewhere ? Theme.of(context).colorScheme.primary : null,
          tooltip: route.portName.isEmpty
              ? 'Audio output'
              : 'Audio output: ${route.portName}',
          padding: widget.compact ? EdgeInsets.zero : null,
          visualDensity: widget.compact ? VisualDensity.compact : null,
          constraints: widget.compact
              ? const BoxConstraints(minWidth: 36, minHeight: 36)
              : null,
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (_) => _AudioOutputSheet(source: widget.source),
          ),
        );
      },
    );
  }
}

/// The current output, a way to change it, and how far behind the player the
/// sound arrives there — measured by the mic for recordings
/// ([SyncCalibrator]), iOS's estimate until then.
class _AudioOutputSheet extends ConsumerStatefulWidget {
  final AudioSyncSource source;

  const _AudioOutputSheet({required this.source});

  @override
  ConsumerState<_AudioOutputSheet> createState() => _AudioOutputSheetState();
}

class _AudioOutputSheetState extends ConsumerState<_AudioOutputSheet> {
  bool _calibrating = false;
  String? _message;

  Future<void> _calibrate() async {
    setState(() {
      _calibrating = true;
      _message = null;
    });
    ref.read(mediaPlaybackServiceProvider).stop();
    ref.read(playbackServiceProvider).stop();
    final playback = ref.read(playbackServiceProvider);
    final media = ref.read(mediaPlaybackServiceProvider);
    final r = await SyncCalibrator.calibrateAll(playback);
    String line(String what, CalibrationResult x) => x.ok
        ? '$what: ${(x.delaySeconds! * 1000).round()} ms '
            '(${x.clicksHeard}/${x.clicksPlayed} clicks)'
        : '$what failed: ${x.failure}';
    if (mounted) {
      setState(() {
        _calibrating = false;
        _message = '${line('Recordings', r.recording)}.\n'
            '${line('Score', r.score)}.';
      });
    }
    // Only if the calibration had to re-apply the app's audio session do the
    // players need rebuilding on it — after the result is on screen, as
    // reloading the soundfont is heavy enough to hold the sheet up.
    if (!SyncCalibrator.lastRunChangedSession) return;
    await WidgetsBinding.instance.endOfFrame;
    unawaited(playback.restartAudio());
    unawaited(media.restartAudio());
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return ValueListenableBuilder<AudioOutputRoute?>(
      valueListenable: AudioOutput.route,
      builder: (context, route, _) => ValueListenableBuilder<Map<String, int>>(
        valueListenable: AudioOutput.calibratedDelaysMs,
        builder: (context, delays, _) {
          final reportedMs = ((route?.latencySeconds ?? 0) * 1000).round();
          final measuredMs = AudioOutput.calibratedDelayMs(source);
          final text = Theme.of(context).textTheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          route == null || route.portName.isEmpty
                              ? 'Audio output'
                              : route.portName,
                          style: text.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('audio_output_change'),
                        icon: const Icon(Icons.airplay, size: 18),
                        label: const Text('Change…'),
                        onPressed: _calibrating ? null : AudioOutput.showPicker,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    measuredMs != null
                        ? 'Sound delay: $measuredMs ms (measured)'
                        : 'Sound delay: $reportedMs ms (iOS estimate)',
                    key: const ValueKey('audio_sync_label'),
                    style: text.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  // One tap calibrates both players on this speaker; each
                  // gets its own delay (AudioOutput.calibratedDelayMs).
                  Row(
                      children: [
                        FilledButton.tonalIcon(
                          key: const ValueKey('audio_sync_calibrate'),
                          icon: _calibrating
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.hearing, size: 18),
                          label: Text(_calibrating ? 'Listening…' : 'Calibrate'),
                          onPressed: _calibrating ? null : _calibrate,
                        ),
                        const Spacer(),
                        if (measuredMs != null && !_calibrating)
                          TextButton(
                            onPressed: () {
                              AudioOutput.setCalibratedDelayMs(
                                  AudioSyncSource.recording, null);
                              AudioOutput.setCalibratedDelayMs(
                                  AudioSyncSource.score, null);
                            },
                            child: const Text('Forget'),
                          ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  Text(
                    _calibrating
                        ? 'Playing clicks — keep the room quiet for about 20 seconds.'
                        : _message ??
                            'Calibrate plays a few clicks and listens '
                                'with the mic. Once per speaker.',
                    key: const ValueKey('audio_sync_message'),
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
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
