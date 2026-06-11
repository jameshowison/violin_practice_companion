import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/duration_step.dart';
import '../models/key_signature.dart';
import '../models/note_event.dart';
import '../models/piece.dart';
import '../services/measure_xml_editor.dart';
import '../services/midi_generator.dart';
import '../services/providers.dart';
import '../widgets/measure_edit_row.dart';
import '../widgets/staff_view.dart';

/// Single-measure note editor for scanned pieces (`docs/plan.md` §6).
///
/// Edits are screen-local and ephemeral: [_notes] is seeded from the parsed
/// measure, mutated in place, and only persisted on Save (which re-serializes
/// just this measure into the piece's MusicXML file and invalidates
/// [parsedPieceProvider] so every view re-renders). Cancel discards.
class EditMeasureScreen extends ConsumerStatefulWidget {
  final int measureNumber;

  const EditMeasureScreen({super.key, required this.measureNumber});

  @override
  ConsumerState<EditMeasureScreen> createState() => _EditMeasureScreenState();
}

// Diatonic staff order; stepping ▲/▼ moves one position (octave wraps at B↔C).
const _steps = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const _accGlyph = TextStyle(fontSize: 18);
const _stepSemitone = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};

class _EditMeasureScreenState extends ConsumerState<EditMeasureScreen> {
  late List<NoteEvent> _notes;
  int? _selectedIndex;
  final ValueNotifier<HighlightEvent?> _noHighlight = ValueNotifier(null);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final parsed = ref.read(parsedPieceProvider).valueOrNull;
    if (parsed != null && parsed.measures.isNotEmpty) {
      final measure = parsed.measures.firstWhere(
        (m) => m.number == widget.measureNumber,
        orElse: () =>
            parsed.measures[(widget.measureNumber - 1).clamp(0, parsed.measures.length - 1)],
      );
      _notes = List.of(measure.notes);
    } else {
      _notes = [];
    }
  }

  @override
  void dispose() {
    _noHighlight.dispose();
    super.dispose();
  }

  NoteEvent? get _selected =>
      _selectedIndex != null ? _notes[_selectedIndex!] : null;

  // ── Pitch math ──────────────────────────────────────────────────────────

  ({String step, int alter, int octave}) _parse(String pitch) {
    final m = RegExp(r'^([A-G])([#b]?)(\d)$').firstMatch(pitch);
    if (m == null) return (step: 'B', alter: 0, octave: 4);
    final alter = m.group(2) == '#' ? 1 : (m.group(2) == 'b' ? -1 : 0);
    return (step: m.group(1)!, alter: alter, octave: int.parse(m.group(3)!));
  }

  String _pitchString(String step, int alter, int octave) =>
      '$step${alter > 0 ? '#' : (alter < 0 ? 'b' : '')}$octave';

  int _midi(String step, int alter, int octave) =>
      (_stepSemitone[step] ?? 0) + (octave + 1) * 12 + alter;

  void _stepPitch(int dir) {
    final i = _selectedIndex;
    if (i == null) return;
    final p = _parse(_notes[i].pitch);
    var idx = _steps.indexOf(p.step);
    var octave = p.octave;
    idx += dir;
    if (idx > 6) {
      idx = 0;
      octave += 1;
    } else if (idx < 0) {
      idx = 6;
      octave -= 1;
    }
    final step = _steps[idx];
    final alter = KeySignature.defaultAlter(_keyFifths, step);
    setState(() {
      // Fresh NoteEvent: pitch change invalidates the stale fingering label.
      _notes[i] = NoteEvent(
        pitch: _pitchString(step, alter, octave),
        midiNumber: _midi(step, alter, octave),
        octave: octave,
        noteValue: _notes[i].noteValue,
        dotted: _notes[i].dotted,
        isRest: false,
      );
    });
  }

  // Explicit alter for each forced accidental; 'none' (null) instead follows
  // the key signature via KeySignature.defaultAlter.
  static const _accidentalAlter = {'flat': -1, 'natural': 0, 'sharp': 1};

  void _setAccidental(String? kind) {
    final i = _selectedIndex;
    if (i == null || _notes[i].isRest) return;
    final n = _notes[i];
    final p = _parse(n.pitch);
    // 'none' (null) → follow the key signature; otherwise the explicit alter.
    final alter = _accidentalAlter[kind] ?? KeySignature.defaultAlter(_keyFifths, p.step);
    final newMidi = _midi(p.step, alter, p.octave);
    final pitchUnchanged = newMidi == n.midiNumber;
    setState(() {
      // Fresh NoteEvent so displayAccidental can be cleared to null (copyWith
      // can't). Keep the fingering only while the sounding pitch is unchanged
      // (e.g. clearing a courtesy natural); a real pitch change invalidates it.
      _notes[i] = NoteEvent(
        pitch: _pitchString(p.step, alter, p.octave),
        midiNumber: newMidi,
        octave: p.octave,
        noteValue: n.noteValue,
        dotted: n.dotted,
        isRest: false,
        displayAccidental: kind,
        scoreFinger: pitchUnchanged ? n.scoreFinger : null,
        fingerNumber: pitchUnchanged ? n.fingerNumber : null,
        fingerString: pitchUnchanged ? n.fingerString : null,
      );
    });
  }

  void _changeDuration({required bool longer}) {
    final i = _selectedIndex;
    if (i == null) return;
    final n = _notes[i];
    final step = longer
        ? DurationStep.next(n.noteValue, n.dotted)
        : DurationStep.previous(n.noteValue, n.dotted);
    setState(() {
      _notes[i] = n.copyWith(noteValue: step.value, dotted: step.dotted);
    });
  }

  void _toggleRest() {
    final i = _selectedIndex;
    if (i == null) return;
    final n = _notes[i];
    setState(() {
      if (n.isRest) {
        _notes[i] = RegExp(r'^[A-G]').hasMatch(n.pitch)
            ? n.copyWith(isRest: false)
            : NoteEvent(
                pitch: 'B4',
                midiNumber: 71,
                octave: 4,
                noteValue: n.noteValue,
                dotted: n.dotted,
                isRest: false,
              );
      } else {
        _notes[i] = n.copyWith(isRest: true);
      }
    });
  }

  void _insert() {
    final i = _selectedIndex;
    if (i == null) return;
    final n = _notes[i];
    setState(() {
      _notes.insert(
        i + 1,
        NoteEvent(
          pitch: n.pitch,
          midiNumber: n.midiNumber,
          octave: n.octave,
          noteValue: NoteValue.quarter,
          dotted: false,
          isRest: n.isRest,
        ),
      );
      _selectedIndex = i + 1;
    });
  }

  void _delete() {
    final i = _selectedIndex;
    if (i == null) return;
    setState(() {
      _notes.removeAt(i);
      _selectedIndex =
          _notes.isEmpty ? null : i.clamp(0, _notes.length - 1);
    });
  }

  // ── Persistence ─────────────────────────────────────────────────────────

  int get _keyFifths =>
      ref.read(parsedPieceProvider).valueOrNull?.keyFifths ?? 0;

  Future<void> _save() async {
    final piece = ref.read(selectedPieceProvider);
    final parsed = ref.read(parsedPieceProvider).valueOrNull;
    if (piece == null || parsed == null) return;

    setState(() => _saving = true);
    try {
      final repo = ref.read(pieceRepositoryProvider);
      final original = await repo.loadMusicXml(piece);
      final newXml = MeasureXmlEditor.replaceMeasureNotes(
          original, widget.measureNumber, _notes, parsed.divisions);

      if (piece.musicXmlFilePath != null) {
        // Already file-backed (a scan or a previously-edited fixture).
        await repo.updateScannedPiece(piece.musicXmlFilePath!, newXml);
      } else {
        // First edit of a bundled fixture: materialize a writable copy and
        // switch the selected piece to it so future loads/edits use the file.
        final filePath =
            await repo.createEditableFixtureFile(piece.id, newXml);
        ref.read(selectedPieceProvider.notifier).state = Piece(
          id: piece.id,
          title: piece.title,
          musicXmlFilePath: filePath,
          sectionsAssetPath: piece.sectionsAssetPath,
          sections: piece.sections,
        );
      }
      ref.invalidate(piecesProvider);
      ref.invalidate(parsedPieceProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Could not save'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final parsed = ref.watch(parsedPieceProvider).valueOrNull;
    final piece = ref.watch(selectedPieceProvider);

    if (parsed == null || piece == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit Measure')),
        body: const Center(child: Text('No piece loaded')),
      );
    }

    final measureCount = parsed.measures.length;
    final previewXml =
        MeasureXmlEditor.buildSingleMeasurePreviewXml(_notes, parsed);

    final expectedUnits = parsed.beatsPerMeasure * 32 ~/ parsed.beatType;
    final actualUnits = _notes.fold<int>(
        0, (s, n) => s + thirtySecondUnits(n.noteValue, n.dotted));
    final mismatch =
        widget.measureNumber != 0 && actualUnits != expectedUnits;
    final actualBeats = actualUnits * parsed.beatType / 32;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Edit Measure ${widget.measureNumber} of $measureCount'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Save',
                  onPressed: _save,
                ),
        ],
      ),
      body: SafeArea(
        // The preview is the flexible (shrinkable) part — it gives back space
        // to the warning banner so the edit row + controls stay pinned at the
        // bottom and never get pushed off-screen.
        child: Column(
          children: [
            // Live single-measure preview (renders blank in Marionette
            // screenshots — a known WebView limitation; verify in-sim).
            Expanded(
              child: StaffView(
                musicXml: previewXml,
                highlightNotifier: _noHighlight,
                bridgeAsset: 'assets/osmd/palette_bridge.html',
              ),
            ),
            const Divider(height: 1),
            // Warning (if the measure's beats don't total) sits to the LEFT of
            // the note cards rather than as a band over the staff, so the
            // preview stays unobstructed and the row height is stable.
            Row(
              children: [
                if (mismatch)
                  _warningBlock(actualBeats, parsed.beatsPerMeasure),
                Expanded(
                  child: MeasureEditRow(
                    notes: _notes,
                    selectedIndex: _selectedIndex,
                    onSelect: (i) => setState(() => _selectedIndex = i),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            _controlPanel(),
          ],
        ),
      ),
    );
  }

  static String _fmtBeats(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  // Compact beat-mismatch warning, sized to match a note card so it sits flush
  // at the left of the note row.
  Widget _warningBlock(double actual, int expected) {
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
          const Icon(Icons.warning_amber_rounded,
              size: 22, color: Colors.deepOrange),
          const SizedBox(height: 4),
          Text(
            '${_fmtBeats(actual)} of $expected',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const Text('beats',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: Colors.black54)),
        ],
      ),
    );
  }

  // ── Control panel ─────────────────────────────────────────────────────────

  Widget _controlPanel() {
    final sel = _selected;
    final hasSel = sel != null;
    final isRest = sel?.isRest ?? false;
    // Which accidental is active: the note's displayAccidental, or 'none' (null)
    // when it follows the key signature. Drives the highlighted button.
    final currentAcc = hasSel && !isRest ? sel.displayAccidental : null;
    final accEnabled = hasSel && !isRest;
    final durLabel = hasSel
        ? DurationStep(sel.noteValue, sel.dotted).label
        : '—';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _group('PITCH', [
            _iconBtn(Icons.arrow_upward,
                onPressed: hasSel ? () => _stepPitch(1) : null),
            const SizedBox(width: 4),
            _iconBtn(Icons.arrow_downward,
                onPressed: hasSel ? () => _stepPitch(-1) : null),
          ]),
          _divider(),
          _group('ACCIDENTAL', [
            _accidentalBtn(
              const Icon(Icons.not_interested, size: 18),
              null,
              currentAcc,
              accEnabled,
              tooltip: 'No accidental (follow key)',
            ),
            const SizedBox(width: 4),
            _accidentalBtn(const Text('♭', style: _accGlyph), 'flat',
                currentAcc, accEnabled),
            const SizedBox(width: 4),
            _accidentalBtn(const Text('♮', style: _accGlyph), 'natural',
                currentAcc, accEnabled),
            const SizedBox(width: 4),
            _accidentalBtn(const Text('♯', style: _accGlyph), 'sharp',
                currentAcc, accEnabled),
          ]),
          _divider(),
          _group(
            'DURATION',
            [
              _iconBtn(Icons.chevron_left,
                  onPressed: hasSel ? () => _changeDuration(longer: false) : null),
              SizedBox(
                width: 92,
                child: Text(durLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12)),
              ),
              _iconBtn(Icons.chevron_right,
                  onPressed: hasSel ? () => _changeDuration(longer: true) : null),
            ],
          ),
          _divider(),
          _group('NOTE / MEASURE', [
            _labelBtn(Icons.swap_horiz, 'rest',
                onPressed: hasSel ? _toggleRest : null),
            const SizedBox(width: 4),
            _labelBtn(Icons.add, 'insert',
                onPressed: hasSel ? _insert : null),
            const SizedBox(width: 4),
            _labelBtn(Icons.remove, 'delete',
                onPressed: hasSel ? _delete : null),
          ]),
        ],
      ),
    );
  }

  Widget _group(String label, List<Widget> children) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade600,
                letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Row(mainAxisSize: MainAxisSize.min, children: children),
      ],
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 56,
        margin: const EdgeInsets.symmetric(horizontal: 14),
        color: Colors.grey.shade300,
      );

  Widget _iconBtn(IconData icon, {VoidCallback? onPressed}) {
    return IconButton.filledTonal(
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _accidentalBtn(
      Widget child, String? kind, String? currentAcc, bool enabled,
      {String? tooltip}) {
    final active = enabled && currentAcc == kind;
    final btn = SizedBox(
      width: 40,
      height: 40,
      child: active
          ? FilledButton(
              onPressed: () => _setAccidental(kind),
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: child,
            )
          : OutlinedButton(
              onPressed: enabled ? () => _setAccidental(kind) : null,
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: child,
            ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: btn) : btn;
  }

  Widget _labelBtn(IconData icon, String label, {VoidCallback? onPressed}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _iconBtn(icon, onPressed: onPressed),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontSize: 9,
                color: onPressed == null
                    ? Colors.grey.shade400
                    : Colors.grey.shade700)),
      ],
    );
  }
}
