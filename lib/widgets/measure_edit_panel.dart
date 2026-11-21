import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicxml_tools/musicxml_tools.dart';
import '../models/note_number_mode.dart';
import '../services/chord_editor.dart';
import '../services/fingering_mapper.dart';
import '../services/measure_edit_session.dart';
import '../services/providers.dart';
import '../services/tuplet_editor.dart';
import 'key_signature_dialog.dart';
import 'measure_edit_row.dart';
import 'time_signature_dialog.dart';

const _accGlyph = TextStyle(fontSize: 18);

/// The measure editor, docked under the piece instead of on a screen of its
/// own, so the bar is edited where it sits: the notation above keeps showing
/// the whole piece, with this bar selected and re-engraved as you edit (see
/// [measureDraftProvider]).
///
/// Three bands: a header (which bar, step to the neighbours, Cancel / Save),
/// the note cards, and the control groups. Nothing here holds state; it all
/// lives in [measureEditProvider].
class MeasureEditPanel extends ConsumerWidget {
  const MeasureEditPanel({super.key});

  /// Opens [measure] for editing and selects it on the score, so the bar being
  /// edited is the one highlighted.
  static void open(WidgetRef ref, int measure) {
    if (ref.read(measureEditProvider.notifier).start(measure)) {
      // The transport is hidden while editing, so nothing may be left playing
      // that there's no button to stop.
      ref.read(activePlaybackServiceProvider).stop();
      ref.read(measureSelectionProvider.notifier).state =
          MeasureSelection(measure, measure);
    }
  }

  /// Ends the session, asking first when there's something to lose. Returns
  /// whether the session is now closed.
  static Future<bool> confirmClose(BuildContext context, WidgetRef ref) async {
    final s = ref.read(measureEditProvider);
    if (s == null) return true;
    if (s.isDirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Discard changes to measure ${s.measureNumber}?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true) return false;
    }
    ref.read(measureEditProvider.notifier).cancel();
    return true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(measureEditProvider);
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    if (s == null || parsed == null) return const SizedBox.shrink();
    final ctl = ref.read(measureEditProvider.notifier);

    // Checked against this bar's own meter: a piece may change meter.
    final meter = s.meter;
    final expectedUnits = meter.units;
    // Chord members add no time (see Measure.actualUnits) — skip them so a
    // chord doesn't read as several sequential notes in the beat total.
    final actualUnits = unitsOf(s.notes);
    final mismatch = s.measureNumber != 0 && actualUnits != expectedUnits;
    final actualBeats = actualUnits * meter.beatType / 32;
    final cs = Theme.of(context).colorScheme;

    return Material(
      key: const ValueKey('measure_edit_panel'),
      color: cs.surfaceContainerLow,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(session: s, measureCount: parsed.measures.length),
            const Divider(height: 1),
            // Warnings sit to the LEFT of the note cards rather than as a band
            // over the staff, so the score stays unobstructed and the row
            // height is stable.
            Row(
              children: [
                // First, in the order a bar's start draws them: key, then
                // time.
                _KeyCard(session: s),
                _TimeCard(session: s),
                if (mismatch)
                  _WarningCard(
                    icon: Icons.warning_amber_rounded,
                    title:
                        '${_fmtBeats(actualBeats)} of ${meter.beats}',
                    subtitle: 'beats',
                  ),
                if (s.lyricsMoved)
                  // One word: "Check lyrics" wraps in a 72px card and
                  // overflows it.
                  const _WarningCard(
                    key: ValueKey('lyrics_warning'),
                    icon: Icons.lyrics_outlined,
                    title: 'Lyrics',
                    subtitle: 'may be out of line',
                  ),
                Expanded(
                  child: MeasureEditRow(
                    notes: s.notes,
                    selectedIndex: s.selectedIndex,
                    onSelect: ctl.select,
                    repeatStart: s.repeatStart,
                    repeatEnd: s.repeatEnd,
                    numberMode: ref.watch(noteNumberModeProvider),
                    fretStyle: ref.watch(fretStyleProvider),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            _ControlPanel(session: s),
          ],
        ),
      ),
    );
  }

  static String _fmtBeats(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}

class _Header extends ConsumerWidget {
  final MeasureEditSession session;
  final int measureCount;

  const _Header({required this.session, required this.measureCount});

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final s = session;
    final lyricsMoved = s.lyricsMoved && s.notesChanged;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(measureEditProvider.notifier).save();
      // The in-editor warning is gone with the editor, so say it once more
      // where the bar can actually be seen under its words.
      if (lyricsMoved) {
        messenger.showSnackBar(SnackBar(
          content: Text('Saved. Check the lyrics in measure '
              '${s.measureNumber} — they may no longer line up.'),
        ));
      }
    } catch (e) {
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not save'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = session;
    final measures =
        ref.watch(parsedPieceProvider).valueOrNull?.measures ?? const [];
    final idx = measures.indexWhere((m) => m.number == s.measureNumber);
    // Stepping to a neighbour would drop this bar's edits, so it waits for
    // Save or Cancel.
    final canStep = !s.isDirty && !s.saving;
    final prev = idx > 0 ? measures[idx - 1].number : null;
    final next =
        idx >= 0 && idx < measures.length - 1 ? measures[idx + 1].number : null;
    final stepHint = s.isDirty ? ' (save or cancel this one first)' : '';

    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('measure_edit_cancel'),
            icon: const Icon(Icons.close),
            tooltip: 'Cancel',
            onPressed:
                s.saving ? null : () => MeasureEditPanel.confirmClose(context, ref),
          ),
          // The arrows hug the title and the group takes all the width
          // between Cancel and Save: on a 375pt phone two Spacers left the
          // title 61pt, which read "Editing…".
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const ValueKey('measure_edit_prev'),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous measure$stepHint',
                  onPressed: canStep && prev != null
                      ? () => MeasureEditPanel.open(ref, prev)
                      : null,
                ),
                Flexible(
                  child: Text(
                    'Measure ${s.measureNumber} of $measureCount',
                    key: const ValueKey('measure_edit_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const ValueKey('measure_edit_next'),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next measure$stepHint',
                  onPressed: canStep && next != null
                      ? () => MeasureEditPanel.open(ref, next)
                      : null,
                ),
              ],
            ),
          ),
          s.saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  key: const ValueKey('measure_edit_save'),
                  icon: const Icon(Icons.check),
                  tooltip: s.isDirty ? 'Save' : 'Done',
                  onPressed: () => _save(context, ref),
                ),
        ],
      ),
    );
  }
}

/// The bar's time signature, drawn as one (3 over 4), ahead of its notes.
/// Solid where the meter is set — the first bar, or a bar that changes it —
/// and faded where the bar just carries on in the meter before it. Tap to
/// change the meter from this bar on, or (not on the first bar) to remove a
/// change. Saved with the bar.
class _TimeCard extends ConsumerWidget {
  final MeasureEditSession session;

  const _TimeCard({required this.session});

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final parsed = ref.read(parsedPieceProvider).valueOrNull;
    if (parsed == null || parsed.measures.isEmpty) return;
    final index =
        parsed.measures.indexWhere((m) => m.number == session.measureNumber);
    final chosen = await showTimeSignatureDialog(
      context,
      piece: parsed,
      measureIndex: index < 0 ? 0 : index,
      current: session.timeChange,
    );
    if (chosen == null) return;
    ref.read(measureEditProvider.notifier).setTimeChange(chosen.meter);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final s = session;
    final sets = s.timeChange != null;
    final color = sets ? cs.onSurface : cs.onSurface.withValues(alpha: 0.38);
    final digits = TextStyle(
        fontSize: 22, height: 1.0, fontWeight: FontWeight.w700, color: color);
    return Semantics(
      button: true,
      label: sets
          ? 'Time signature ${s.meter}'
          : 'Time signature ${s.meter}, same as before',
      child: InkWell(
        key: const ValueKey('measure_time_card'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _edit(context, ref),
        child: Container(
          width: 56,
          height: 96,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: s.timeChanged ? cs.primary : cs.outlineVariant,
                width: s.timeChanged ? 2 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${s.meter.beats}', style: digits),
              Text('${s.meter.beatType}', style: digits),
              const SizedBox(height: 6),
              Text(sets ? 'time' : 'same',
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bar's key signature as a count (`2♯`) over its major key's name,
/// ahead of the time card. Solid where the key is set — the first bar, or a
/// bar that changes it — and faded where the bar carries on in the key
/// before it. Tap to fix a misread key from this bar on; the notes that were
/// following the old key move with it, and the score shows them before Save.
class _KeyCard extends ConsumerWidget {
  final MeasureEditSession session;

  const _KeyCard({required this.session});

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final parsed = ref.read(parsedPieceProvider).valueOrNull;
    if (parsed == null || parsed.measures.isEmpty) return;
    final index =
        parsed.measures.indexWhere((m) => m.number == session.measureNumber);
    final chosen = await showKeySignatureDialog(
      context,
      piece: parsed,
      measureIndex: index < 0 ? 0 : index,
      current: session.keyChange,
    );
    if (chosen == null) return;
    ref.read(measureEditProvider.notifier).setKeyChange(chosen.fifths);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final s = session;
    final sets = s.keyChange != null;
    final color = sets ? cs.onSurface : cs.onSurface.withValues(alpha: 0.38);
    final signs = KeySignature.signs(s.key);
    return Semantics(
      button: true,
      label: 'Key signature ${signs.isEmpty ? 'with no sharps or flats' : signs}'
          '${sets ? '' : ', same as before'}',
      child: InkWell(
        key: const ValueKey('measure_key_card'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _edit(context, ref),
        child: Container(
          // Narrower than the time card: on a 375pt phone every point here
          // comes out of the note row.
          width: 48,
          height: 96,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: s.keyChanged ? cs.primary : cs.outlineVariant,
                width: s.keyChanged ? 2 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(KeySignature.label(s.key),
                  style: TextStyle(
                      fontSize: 20,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      color: color)),
              const SizedBox(height: 4),
              Text(MusicXmlParser.keyName(s.key, KeyMode.major),
                  style: TextStyle(fontSize: 13, color: color)),
              const SizedBox(height: 6),
              Text(sets ? 'key' : 'same',
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Beat-mismatch / lyrics warning, sized to match a note card so it sits flush
/// at the left of the note row.
class _WarningCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _WarningCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 96,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.deepOrange.shade200),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22, color: Colors.deepOrange),
          const SizedBox(height: 4),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87)),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: Colors.black54)),
        ],
      ),
    );
  }
}

class _ControlPanel extends ConsumerWidget {
  final MeasureEditSession session;

  const _ControlPanel({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = session;
    final ctl = ref.read(measureEditProvider.notifier);
    final sel = s.selected;
    final hasSel = sel != null;
    final isRest = sel?.isRest ?? false;
    // Which accidental is active: the note's displayAccidental, or 'none'
    // (null) when it follows the key signature.
    final currentAcc = hasSel && !isRest ? sel.displayAccidental : null;
    final accEnabled = hasSel && !isRest;
    // The duration shown (and stepped) is the chord's, read from the primary.
    final primary = hasSel
        ? s.notes[ChordEditor.primaryIndexOf(s.notes, s.selectedIndex!)]
        : null;
    final durLabel = primary != null
        ? DurationStep(primary.noteValue, primary.dotted).label
        : '—';
    final restBlocked = ChordEditor.restBlockedReason(s.notes, s.selectedIndex);

    Widget accidental(Widget child, String? kind, {String? tooltip}) =>
        _accidentalBtn(child, kind, currentAcc, accEnabled,
            onTap: () => ctl.setAccidental(kind), tooltip: tooltip);

    return SingleChildScrollView(
      // Keeps the row where it was scrolled to if the panel is rebuilt.
      key: const PageStorageKey('measure_edit_controls'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section start marks the SELECTED note as the beginning of a
          // section (sub-measure precision — a pickup belongs to what follows).
          // First because it's the control reached for most: fixing a scan's
          // sections touches far more bars than fixing its notes.
          _group(context, 'SECTION', [_sectionToggle(context, ctl)]),
          _divider(context),
          _group(context, 'PITCH', [
            _iconBtn(Icons.arrow_upward,
                onPressed: hasSel ? () => ctl.stepPitch(1) : null),
            const SizedBox(width: 4),
            _iconBtn(Icons.arrow_downward,
                onPressed: hasSel ? () => ctl.stepPitch(-1) : null),
          ]),
          _divider(context),
          _group(context, 'ACCIDENTAL', [
            accidental(const Icon(Icons.not_interested, size: 18), null,
                tooltip: 'No accidental (follow key)'),
            const SizedBox(width: 4),
            accidental(const Text('♭', style: _accGlyph), 'flat'),
            const SizedBox(width: 4),
            accidental(const Text('♮', style: _accGlyph), 'natural',
                tooltip: "Scanned naturals aren't detected — set this "
                    'manually if the note should be natural'),
            const SizedBox(width: 4),
            accidental(const Text('♯', style: _accGlyph), 'sharp'),
          ]),
          // Open string vs 4th finger. Violin only: in fret mode it has no
          // fingering to show, as in the piece view's Instrument panel.
          if (ref.watch(noteNumberModeProvider) ==
              NoteNumberMode.violinFingering) ...[
            _divider(context),
            _group(context, 'STRING', [_stringChoice(context, ctl)]),
          ],
          _divider(context),
          _group(context, 'BOW', [_bowChoice(context, ctl)]),
          _divider(context),
          _group(context, 'DURATION', [
            // Value name sits above the ◀ ▶ buttons so the group stays narrow.
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 16,
                  child: Text(durLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11)),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _iconBtn(Icons.chevron_left,
                        onPressed: hasSel
                            ? () => ctl.changeDuration(longer: false)
                            : null),
                    const SizedBox(width: 4),
                    _iconBtn(Icons.chevron_right,
                        onPressed: hasSel
                            ? () => ctl.changeDuration(longer: true)
                            : null),
                  ],
                ),
              ],
            ),
            // A triplet is a duration: three in the time of two. Here rather
            // than a group of its own, which pushed the row past an iPad.
            const SizedBox(width: 6),
            _tripletToggle(context, ctl),
          ]),
          _divider(context),
          // Stacking sits next to DURATION because the two interact: joining a
          // stem adopts the target's duration, and duration then applies to
          // the whole stack.
          _group(context, 'CHORD', [_stackToggle(context, ctl)]),
          _divider(context),
          _group(context, 'NOTE / MEASURE', [
            _labelBtn(context, Icons.swap_horiz, 'rest',
                onPressed:
                    hasSel && restBlocked == null ? ctl.toggleRest : null,
                tooltip: restBlocked),
            const SizedBox(width: 4),
            _labelBtn(context, Icons.add, 'insert',
                onPressed: hasSel ? ctl.insert : null),
            const SizedBox(width: 4),
            _labelBtn(context, Icons.remove, 'delete',
                onPressed: hasSel ? ctl.delete : null),
          ]),
          _divider(context),
          // Repeat barlines act on the whole measure, so these are always
          // enabled regardless of which note (if any) is selected. The score
          // above shows them as soon as they're toggled.
          _group(context, 'REPEAT', [
            _squareToggle(context, Text('|:', style: _accGlyph), 'start',
                active: s.repeatStart, onTap: ctl.toggleRepeatStart),
            const SizedBox(width: 4),
            _squareToggle(context, Text(':|', style: _accGlyph), 'end',
                active: s.repeatEnd, onTap: ctl.toggleRepeatEnd),
            const SizedBox(width: 4),
            // First/second ending (volta): tap to step none → 1. → 2. → none.
            // Saved with the bar; mark bar 8 "1." and bar 9 "2." and the
            // score draws the brackets and playback takes each once.
            _squareToggle(
                context,
                Text(
                    s.endings.isEmpty
                        ? '⌐'
                        : '${(s.endings.toList()..sort()).join(',')}.',
                    style: _accGlyph),
                'ending',
                key: const ValueKey('measure_ending_toggle'),
                active: s.endings.isNotEmpty,
                onTap: ctl.cycleEnding),
          ]),
        ],
      ),
    );
  }

  Future<void> _editSectionMarker(
      BuildContext context, MeasureEditController ctl) async {
    final existing = session.markerAtSelection;
    final controller = TextEditingController(text: existing?.label ?? '');
    final label = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing != null ? 'Edit section start' : 'Mark section start'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Section label',
            hintText: 'e.g. A, B',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (label == null) return; // cancelled
    ctl.setSectionMarker(label);
  }

  /// Open string / 4th finger for the selected note: `auto` (the piece's
  /// setting decides), `0` or `4`. Only enabled on D4, A4 and E5.
  Widget _stringChoice(BuildContext context, MeasureEditController ctl) {
    final sel = session.selected;
    final enabled = sel != null &&
        !sel.isRest &&
        FingeringMapper.hasFourthFingerChoice(sel.midiNumber);
    final pinned = enabled ? sel.scoreFinger : null;
    final current = (pinned == 0 || pinned == 4) ? pinned : null;
    final why = enabled
        ? ''
        : ' Only D, A and E (open strings above G) have the choice.';
    Widget btn(int? value, Widget child, String caption, String tooltip) =>
        Tooltip(
          message: '$tooltip$why',
          child: _squareToggle(context, child, caption,
              key: ValueKey('string_choice_$caption'),
              active: enabled && current == value,
              onTap: enabled ? () => ctl.setStringChoice(value) : null),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // An icon, not "A": a letter beside 0 and 4 reads as the A string.
        btn(null, const Icon(Icons.autorenew, size: 18), 'auto',
            "Follow the piece's setting."),
        const SizedBox(width: 4),
        btn(0, const Text('0', style: TextStyle(fontSize: 15)), 'open',
            'Play on the open string.'),
        const SizedBox(width: 4),
        btn(4, const Text('4', style: TextStyle(fontSize: 15)), '4th',
            'Play with the 4th finger on the string below.'),
      ],
    );
  }

  /// Down-bow (⊓) / up-bow (V) for the selected note. Filled while the note
  /// carries that mark; tapping the filled one clears it. A chord's bowing is
  /// its stem's, so a member shows (and sets) its primary's.
  Widget _bowChoice(BuildContext context, MeasureEditController ctl) {
    final i = session.selectedIndex;
    final primary =
        i == null ? null : session.notes[ChordEditor.primaryIndexOf(session.notes, i)];
    final enabled = primary != null && !primary.isRest;
    final current = enabled ? primary.bowing : null;
    Widget btn(Bowing value, String caption, String tooltip) {
      final active = current == value;
      return Tooltip(
        message: enabled ? tooltip : 'Select a note to mark its bowing.',
        child: _squareToggle(
          context,
          Builder(
            // The button's own foreground, so the glyph reads on the filled
            // (active) and outlined states alike, and greys when disabled.
            builder: (context) => CustomPaint(
              size: const Size(16, 16),
              painter: BowGlyphPainter(value,
                  color: IconTheme.of(context).color ??
                      DefaultTextStyle.of(context).style.color ??
                      Colors.black),
            ),
          ),
          caption,
          key: ValueKey('bowing_$caption'),
          active: enabled && active,
          onTap: enabled ? () => ctl.setBowing(value) : null,
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Bowing.down, 'down', 'Down-bow: pull the bow, frog to tip.'),
        const SizedBox(width: 4),
        btn(Bowing.up, 'up', 'Up-bow: push the bow, tip to frog.'),
      ],
    );
  }

  // Stack / unstack the selected note onto the previous note's stem. Filled
  // while the note IS stacked (tap to detach), outlined when it can be
  // stacked, disabled otherwise — with the reason as the tooltip.
  Widget _stackToggle(BuildContext context, MeasureEditController ctl) {
    final i = session.selectedIndex;
    final stacked = ChordEditor.canUnstack(session.notes, i);
    final blocked = ChordEditor.stackBlockedReason(session.notes, i);
    return Tooltip(
      message: stacked
          ? 'Unstack from the chord — this note becomes its own beat.'
          : (blocked ?? 'Stack on the previous note (chord).'),
      child: _squareToggle(
        context,
        Icon(stacked ? Icons.layers_clear : Icons.layers, size: 20),
        stacked ? 'unstack' : 'stack',
        active: stacked,
        onTap: stacked || blocked == null ? ctl.toggleStack : null,
      ),
    );
  }

  // Make the selected note and the next two a triplet, or undo the one it's
  // in. Filled while the note IS in a triplet; disabled, with the reason as
  // the tooltip, when the three notes aren't alike.
  Widget _tripletToggle(BuildContext context, MeasureEditController ctl) {
    final i = session.selectedIndex;
    final inOne = TupletEditor.groupOf(session.notes, i) != null;
    final blocked = TupletEditor.blockedReason(session.notes, i);
    return Tooltip(
      message: inOne
          ? 'Undo the triplet — the three notes go back to their full length.'
          : (blocked ??
              'Make this note and the next two a triplet: three in the time '
                  'of two.'),
      child: _squareToggle(
        context,
        const Text('3', style: _accGlyph),
        inOne ? 'undo' : 'triplet',
        key: const ValueKey('triplet_toggle'),
        active: inOne,
        onTap: blocked == null ? ctl.toggleTriplet : null,
      ),
    );
  }

  // Shows the marker's label when the selected note begins a section, else a
  // "+" to add one. Disabled until a note is selected.
  Widget _sectionToggle(BuildContext context, MeasureEditController ctl) {
    final marker = session.markerAtSelection;
    return _squareToggle(
      context,
      Text(marker != null ? marker.label : '+', style: _accGlyph),
      'start',
      active: marker != null,
      onTap: session.selectedIndex != null
          ? () => _editSectionMarker(context, ctl)
          : null,
    );
  }

  /// A 40×40 rounded-square button (filled when [active]) with a caption.
  static Widget _squareToggle(BuildContext context, Widget child, String label,
      {Key? key, required bool active, VoidCallback? onTap}) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: active
              ? FilledButton(
                  key: key,
                  onPressed: onTap,
                  style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero, shape: shape),
                  child: child,
                )
              : OutlinedButton(
                  key: key,
                  onPressed: onTap,
                  style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero, shape: shape),
                  child: child,
                ),
        ),
        const SizedBox(height: 2),
        Text(label, style: _captionStyle(context)),
      ],
    );
  }

  static TextStyle _captionStyle(BuildContext context, {bool enabled = true}) {
    final on = Theme.of(context).colorScheme.onSurfaceVariant;
    return TextStyle(
        fontSize: 9, color: enabled ? on : on.withValues(alpha: 0.4));
  }

  static Widget _group(BuildContext context, String label, List<Widget> children) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 0.5)),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: children),
      ],
    );
  }

  static Widget _divider(BuildContext context) => Container(
        width: 1,
        height: 56,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: Theme.of(context).colorScheme.outlineVariant,
      );

  static Widget _iconBtn(IconData icon, {VoidCallback? onPressed}) {
    return IconButton.filledTonal(
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    );
  }

  static Widget _accidentalBtn(
      Widget child, String? kind, String? currentAcc, bool enabled,
      {required VoidCallback onTap, String? tooltip}) {
    final active = enabled && currentAcc == kind;
    final btn = SizedBox(
      width: 40,
      height: 40,
      child: active
          ? FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero, shape: const CircleBorder()),
              child: child,
            )
          : OutlinedButton(
              onPressed: enabled ? onTap : null,
              style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero, shape: const CircleBorder()),
              child: child,
            ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: btn) : btn;
  }

  static Widget _labelBtn(BuildContext context, IconData icon, String label,
      {VoidCallback? onPressed, String? tooltip}) {
    final btn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _iconBtn(icon, onPressed: onPressed),
        const SizedBox(height: 2),
        Text(label, style: _captionStyle(context, enabled: onPressed != null)),
      ],
    );
    return tooltip != null ? Tooltip(message: tooltip, child: btn) : btn;
  }
}

/// The string player's bow marks as engraved: down-bow ⊓ (a heavy bar on two
/// legs) and up-bow V. Drawn rather than set in a font, because neither glyph
/// is reliable outside a music font. Fills [size].
class BowGlyphPainter extends CustomPainter {
  final Bowing bowing;
  final Color color;

  const BowGlyphPainter(this.bowing, {required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final thin = math.max(1.0, w * 0.1);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = thin;
    switch (bowing) {
      case Bowing.down:
        final bar = math.max(thin * 1.6, h * 0.28);
        canvas.drawRect(
            Rect.fromLTWH(0, 0, w, bar), Paint()..color = color);
        canvas.drawLine(
            Offset(thin / 2, bar), Offset(thin / 2, h), stroke);
        canvas.drawLine(
            Offset(w - thin / 2, bar), Offset(w - thin / 2, h), stroke);
      case Bowing.up:
        final path = Path()
          ..moveTo(w * 0.1, 0)
          ..lineTo(w / 2, h)
          ..lineTo(w * 0.9, 0);
        canvas.drawPath(path, stroke..strokeJoin = StrokeJoin.miter);
    }
  }

  @override
  bool shouldRepaint(BowGlyphPainter old) =>
      old.bowing != bowing || old.color != color;
}
