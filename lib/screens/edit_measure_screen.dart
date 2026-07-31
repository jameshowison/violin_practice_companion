import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/duration_step.dart';
import '../models/key_signature.dart';
import '../models/note_event.dart';
import '../models/section.dart';
import '../services/chord_editor.dart';
import '../services/measure_xml_editor.dart';
import '../services/midi_generator.dart';
import '../services/providers.dart';
import '../widgets/measure_edit_row.dart';
import '../widgets/staff_view.dart';
import '../widgets/staff_view_verovio.dart';

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
  // Repeat barlines on this measure, seeded from the parsed measure and toggled
  // by the REPEAT control group. Persisted via MeasureXmlEditor.setMeasureRepeats.
  bool _repeatStart = false;
  bool _repeatEnd = false;
  // The whole piece's section start markers, edited via the SECTION control and
  // persisted to the section-override sidecar on Save. Markers live outside the
  // MusicXML, so they're tracked independently of the note/repeat edits.
  late List<Section> _sectionStarts;
  final ValueNotifier<HighlightEvent?> _noHighlight = ValueNotifier(null);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final parsed = ref.read(parsedPieceProvider).valueOrNull;
    _sectionStarts = List.of(ref.read(selectedPieceProvider)?.sections ?? const []);
    if (parsed != null && parsed.measures.isNotEmpty) {
      final measure = parsed.measures.firstWhere(
        (m) => m.number == widget.measureNumber,
        orElse: () =>
            parsed.measures[(widget.measureNumber - 1).clamp(0, parsed.measures.length - 1)],
      );
      // Repair the chord invariant up front — OMR output can carry a stray
      // leading <chord/> or a member whose duration drifted from its primary.
      _notes = ChordEditor.normalize(measure.notes);
      _repeatStart = measure.repeatStart;
      _repeatEnd = measure.repeatEnd;
    } else {
      _notes = [];
    }
  }

  /// Index a section marker for the current selection would occupy. Every note
  /// in a chord shares one onset, so a marker always sits on the stack's
  /// primary — selecting any member addresses the same marker.
  int? get _markerIndex {
    final i = _selectedIndex;
    return i == null ? null : ChordEditor.primaryIndexOf(_notes, i);
  }

  /// The marker (if any) that starts a section at the currently-selected note.
  Section? get _markerAtSelection {
    final i = _markerIndex;
    if (i == null) return null;
    for (final s in _sectionStarts) {
      if (s.startMeasure == widget.measureNumber && s.startNote == i) return s;
    }
    return null;
  }

  /// Add / edit / remove a section start marker at the selected note. The label
  /// is typed in a small dialog; an empty label clears the marker.
  Future<void> _editSectionMarker() async {
    final i = _markerIndex;
    if (i == null) return;
    final existing = _markerAtSelection;
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
    setState(() {
      _sectionStarts.removeWhere(
          (s) => s.startMeasure == widget.measureNumber && s.startNote == i);
      if (label.isNotEmpty) {
        _sectionStarts.add(Section(
            label: label, startMeasure: widget.measureNumber, startNote: i));
      }
    });
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
      // ChordEditor.repitch drops the now-stale fingering but carries the
      // structural fields (chord membership, chord symbol, rhythm) through.
      _notes = ChordEditor.replaceAt(
        _notes,
        i,
        ChordEditor.repitch(
          _notes[i],
          pitch: _pitchString(step, alter, octave),
          midiNumber: _midi(step, alter, octave),
          octave: octave,
        ),
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
      // Keep the fingering only while the sounding pitch is unchanged (e.g.
      // clearing a courtesy natural); a real pitch change invalidates it.
      _notes = ChordEditor.replaceAt(
        _notes,
        i,
        ChordEditor.repitch(
          n,
          pitch: _pitchString(p.step, alter, p.octave),
          midiNumber: newMidi,
          octave: p.octave,
          displayAccidental: kind,
          keepFingering: pitchUnchanged,
        ),
      );
    });
  }

  void _changeDuration({required bool longer}) {
    final i = _selectedIndex;
    if (i == null) return;
    // Step from the PRIMARY, not the selected member, so a member that somehow
    // drifted can't propagate its value to the rest of the stack.
    final p = _notes[ChordEditor.primaryIndexOf(_notes, i)];
    final step = longer
        ? DurationStep.next(p.noteValue, p.dotted)
        : DurationStep.previous(p.noteValue, p.dotted);
    setState(() {
      _notes = ChordEditor.setDuration(_notes, i, step);
    });
  }

  void _toggleRest() {
    final i = _selectedIndex;
    if (i == null) return;
    setState(() {
      _notes = ChordEditor.toggleRest(_notes, i);
    });
  }

  /// Joins the selected note to the previous note's stem, or detaches it again.
  void _toggleStack() {
    final i = _selectedIndex;
    if (i == null) return;
    setState(() {
      _notes = ChordEditor.canUnstack(_notes, i)
          ? ChordEditor.unstack(_notes, i)
          : ChordEditor.stack(_notes, i);
      // A marker on a note that just became a member has to follow its stack's
      // primary — a section can't begin mid-stem.
      _sectionStarts = ChordEditor.normalizeMarkers(
          _notes, _sectionStarts, widget.measureNumber);
    });
  }

  void _insert() {
    final i = _selectedIndex;
    if (i == null) return;
    final n = _notes[i];
    setState(() {
      final r = ChordEditor.insertAfter(
        _notes,
        i,
        NoteEvent(
          pitch: n.pitch,
          midiNumber: n.midiNumber,
          octave: n.octave,
          noteValue: NoteValue.quarter,
          dotted: false,
          isRest: n.isRest,
        ),
      );
      _notes = r.notes;
      _selectedIndex = r.selectedIndex;
    });
  }

  void _delete() {
    final i = _selectedIndex;
    if (i == null) return;
    setState(() {
      final r = ChordEditor.deleteAt(_notes, i);
      _notes = r.notes;
      _selectedIndex = r.selectedIndex;
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
      var newXml = MeasureXmlEditor.replaceMeasureNotes(
          original, widget.measureNumber, _notes, parsed.divisions);
      newXml = MeasureXmlEditor.setMeasureRepeats(
          newXml, widget.measureNumber,
          start: _repeatStart, end: _repeatEnd);

      // Materializes a writable copy on a bundled fixture's first edit, so the
      // returned piece is always file-backed.
      final updated = await repo.writeEditedMusicXml(piece, newXml);
      // Persist section markers (sidecar) and reflect them on the selected
      // piece so the detail screen re-renders sections without a re-select.
      await repo.saveSections(piece.id, _sectionStarts);
      ref.read(selectedPieceProvider.notifier).state =
          updated.copyWith(sections: _sectionStarts);
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
    // Repeats are shown as Flutter badge overlays (below), NOT baked into the
    // preview XML: OSMD auto-closes an unclosed forward repeat onto the same
    // measure's right barline, which would make a lone start-repeat look like
    // both a start and an end. The saved file carries the real barlines.
    final previewXml =
        MeasureXmlEditor.buildSingleMeasurePreviewXml(_notes, parsed);

    final expectedUnits = parsed.beatsPerMeasure * 32 ~/ parsed.beatType;
    // Chord members add no time (see Measure.actualUnits) — skip them so a
    // chord doesn't read as several sequential notes in the beat total.
    final actualUnits = _notes.fold<int>(
        0,
        (s, n) =>
            n.isChord ? s : s + thirtySecondUnits(n.noteValue, n.dotted));
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
            // Live single-measure preview. The native Verovio renderer draws
            // in-pipeline (Marionette-visible); the OSMD palette bridge renders
            // blank in Marionette screenshots (a WebView limitation).
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ref.watch(staffRendererProvider) ==
                            StaffRenderer.verovio
                        ? StaffViewVerovio(
                            musicXml: previewXml,
                            highlightNotifier: _noHighlight,
                          )
                        : StaffView(
                            musicXml: previewXml,
                            highlightNotifier: _noHighlight,
                            bridgeAsset: 'assets/osmd/palette_bridge.html',
                          ),
                  ),
                  // Repeat indicators, one per active toggle — driven directly
                  // by the toggle state so each shows independently.
                  if (_repeatStart)
                    const Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(child: _RepeatBadge('|:')),
                    ),
                  if (_repeatEnd)
                    const Positioned(
                      right: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(child: _RepeatBadge(':|')),
                    ),
                ],
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
    // The duration shown (and stepped) is the chord's, read from the primary —
    // selecting a member shows the value the whole stack actually carries.
    final primary = hasSel
        ? _notes[ChordEditor.primaryIndexOf(_notes, _selectedIndex!)]
        : null;
    final durLabel = primary != null
        ? DurationStep(primary.noteValue, primary.dotted).label
        : '—';
    final restBlocked = ChordEditor.restBlockedReason(_notes, _selectedIndex);

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
                              ? () => _changeDuration(longer: false)
                              : null),
                      const SizedBox(width: 4),
                      _iconBtn(Icons.chevron_right,
                          onPressed: hasSel
                              ? () => _changeDuration(longer: true)
                              : null),
                    ],
                  ),
                ],
              ),
            ],
          ),
          _divider(),
          // Stacking sits next to DURATION because the two interact: joining a
          // stem adopts the target's duration, and duration then applies to the
          // whole stack.
          _group('CHORD', [
            _stackToggle(),
          ]),
          _divider(),
          _group('NOTE / MEASURE', [
            _labelBtn(Icons.swap_horiz, 'rest',
                onPressed: hasSel && restBlocked == null ? _toggleRest : null,
                tooltip: restBlocked),
            const SizedBox(width: 4),
            _labelBtn(Icons.add, 'insert',
                onPressed: hasSel ? _insert : null),
            const SizedBox(width: 4),
            _labelBtn(Icons.remove, 'delete',
                onPressed: hasSel ? _delete : null),
          ]),
          _divider(),
          // Repeat barlines act on the whole measure, so these are always
          // enabled regardless of which note (if any) is selected.
          _group('REPEAT', [
            _repeatToggle('|:', 'start', _repeatStart,
                () => setState(() => _repeatStart = !_repeatStart)),
            const SizedBox(width: 4),
            _repeatToggle(':|', 'end', _repeatEnd,
                () => setState(() => _repeatEnd = !_repeatEnd)),
          ]),
          _divider(),
          // Section start marks the SELECTED note as the beginning of a section
          // (sub-measure precision — e.g. a pickup belongs to what follows).
          _group('SECTION', [
            _sectionToggle(),
          ]),
        ],
      ),
    );
  }

  // A section-start toggle: shows the marker's label when the selected note
  // begins a section, else a "+" to add one. Disabled until a note is selected.
  Widget _sectionToggle() {
    final marker = _markerAtSelection;
    final active = marker != null;
    final enabled = _selectedIndex != null;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    final child = Text(active ? marker.label : '+', style: _accGlyph);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: active
              ? FilledButton(
                  onPressed: enabled ? _editSectionMarker : null,
                  style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero, shape: shape),
                  child: child,
                )
              : OutlinedButton(
                  onPressed: enabled ? _editSectionMarker : null,
                  style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero, shape: shape),
                  child: child,
                ),
        ),
        const SizedBox(height: 2),
        Text('start', style: TextStyle(fontSize: 9, color: Colors.grey.shade700)),
      ],
    );
  }

  // Stack / unstack the selected note onto the previous note's stem. Filled
  // while the note IS stacked (tap to detach), outlined when it can be stacked,
  // disabled otherwise — with the reason as the tooltip, so the enabled state
  // and its explanation come from the same ChordEditor call.
  Widget _stackToggle() {
    final i = _selectedIndex;
    final stacked = ChordEditor.canUnstack(_notes, i);
    final blocked = ChordEditor.stackBlockedReason(_notes, i);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    final icon = Icon(stacked ? Icons.layers_clear : Icons.layers, size: 20);
    return Tooltip(
      message: stacked
          ? 'Unstack from the chord — this note becomes its own beat.'
          : (blocked ?? 'Stack on the previous note (chord).'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: stacked
                ? FilledButton(
                    onPressed: _toggleStack,
                    style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero, shape: shape),
                    child: icon,
                  )
                : OutlinedButton(
                    onPressed: blocked == null ? _toggleStack : null,
                    style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero, shape: shape),
                    child: icon,
                  ),
          ),
          const SizedBox(height: 2),
          Text(stacked ? 'unstack' : 'stack',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade700)),
        ],
      ),
    );
  }

  // A measure-level repeat toggle: a square glyph button (filled when active)
  // with a caption below.
  Widget _repeatToggle(
      String glyph, String label, bool active, VoidCallback onTap) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: active
              ? FilledButton(
                  onPressed: onTap,
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: shape,
                  ),
                  child: Text(glyph, style: _accGlyph),
                )
              : OutlinedButton(
                  onPressed: onTap,
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: shape,
                  ),
                  child: Text(glyph, style: _accGlyph),
                ),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 9, color: Colors.grey.shade700)),
      ],
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
        margin: const EdgeInsets.symmetric(horizontal: 8),
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

  Widget _labelBtn(IconData icon, String label,
      {VoidCallback? onPressed, String? tooltip}) {
    final btn = Column(
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
    return tooltip != null ? Tooltip(message: tooltip, child: btn) : btn;
  }
}

/// A repeat indicator drawn over the live preview (the staff itself stays
/// repeat-free to dodge OSMD's auto-close of an unmatched forward repeat).
class _RepeatBadge extends StatelessWidget {
  final String glyph;
  const _RepeatBadge(this.glyph);

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(
        glyph,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
