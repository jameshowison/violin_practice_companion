import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/duration_step.dart';
import '../models/key_signature.dart';
import '../models/note_event.dart';
import '../models/parsed_piece.dart';
import '../models/section.dart';
import 'chord_editor.dart';
import 'fingering_mapper.dart';
import 'measure_xml_editor.dart';
import 'providers.dart';

/// The bar being edited in place on the piece screen (open gaps:
/// `docs/plan.md` §2). Replaces the old full-screen `EditMeasureScreen`: the
/// piece stays on screen, the edit controls dock beneath it, and every edit is
/// engraved in context through [measureDraftProvider] before Save writes it.
///
/// Edits are ephemeral until [MeasureEditController.save], which re-serializes
/// just this measure into the piece's MusicXML file. Cancel discards.
class MeasureEditSession {
  final String pieceId;
  final int measureNumber;
  final List<NoteEvent> notes;

  /// The bar as it was opened, to tell when an edit has moved its lyrics and
  /// whether there is anything to save.
  final List<NoteEvent> originalNotes;
  final int? selectedIndex;
  final bool repeatStart;
  final bool repeatEnd;
  final bool originalRepeatStart;
  final bool originalRepeatEnd;

  /// The whole piece's section start markers. They live outside the MusicXML
  /// (a sidecar), so they're tracked apart from the note/repeat edits.
  final List<Section> sectionStarts;
  final List<Section> originalSectionStarts;

  /// The time signature this bar starts, or null when it carries on in
  /// [meterBefore]. On the first bar it is the piece's opening meter and
  /// never null. Written on Save, not drafted: the draft re-engraves notes.
  final Meter? timeChange;
  final Meter? originalTimeChange;

  /// The meter in force just before this bar — what a bar with no
  /// [timeChange] is in. The opening meter for the first bar.
  final Meter meterBefore;

  /// Whether this is the piece's first bar, whose meter can be changed but
  /// not removed.
  final bool isFirstMeasure;
  final bool saving;

  const MeasureEditSession({
    required this.pieceId,
    required this.measureNumber,
    required this.notes,
    required this.originalNotes,
    required this.selectedIndex,
    required this.repeatStart,
    required this.repeatEnd,
    required this.originalRepeatStart,
    required this.originalRepeatEnd,
    required this.sectionStarts,
    required this.originalSectionStarts,
    this.timeChange,
    this.originalTimeChange,
    this.meterBefore = const Meter(4, 4),
    this.isFirstMeasure = false,
    this.saving = false,
  });

  /// The meter this bar is in, with any pending change.
  Meter get meter => timeChange ?? meterBefore;

  NoteEvent? get selected =>
      selectedIndex != null && selectedIndex! < notes.length
          ? notes[selectedIndex!]
          : null;

  /// The index a section marker for the selection would occupy. Every note in
  /// a chord shares one onset, so a marker always sits on the stack's primary.
  int? get markerIndex {
    final i = selectedIndex;
    return i == null ? null : ChordEditor.primaryIndexOf(notes, i);
  }

  Section? get markerAtSelection {
    final i = markerIndex;
    if (i == null) return null;
    for (final s in sectionStarts) {
      if (s.startMeasure == measureNumber && s.startNote == i) return s;
    }
    return null;
  }

  bool get notesChanged => !_sameNotes(notes, originalNotes);
  bool get repeatsChanged =>
      repeatStart != originalRepeatStart || repeatEnd != originalRepeatEnd;
  bool get sectionsChanged => !_sameSections(sectionStarts, originalSectionStarts);
  bool get timeChanged => timeChange != originalTimeChange;
  bool get isDirty =>
      notesChanged || repeatsChanged || sectionsChanged || timeChanged;

  bool get lyricsMoved =>
      ChordEditor.lyricsMayBeMisaligned(originalNotes, notes);

  MeasureEditSession copyWith({
    List<NoteEvent>? notes,
    int? selectedIndex,
    bool clearSelection = false,
    bool? repeatStart,
    bool? repeatEnd,
    List<Section>? sectionStarts,
    Meter? timeChange,
    bool clearTimeChange = false,
    bool? saving,
  }) =>
      MeasureEditSession(
        pieceId: pieceId,
        measureNumber: measureNumber,
        notes: notes ?? this.notes,
        originalNotes: originalNotes,
        selectedIndex:
            clearSelection ? null : (selectedIndex ?? this.selectedIndex),
        repeatStart: repeatStart ?? this.repeatStart,
        repeatEnd: repeatEnd ?? this.repeatEnd,
        originalRepeatStart: originalRepeatStart,
        originalRepeatEnd: originalRepeatEnd,
        sectionStarts: sectionStarts ?? this.sectionStarts,
        originalSectionStarts: originalSectionStarts,
        timeChange:
            clearTimeChange ? null : (timeChange ?? this.timeChange),
        originalTimeChange: originalTimeChange,
        meterBefore: meterBefore,
        isFirstMeasure: isFirstMeasure,
        saving: saving ?? this.saving,
      );

  static bool _sameNotes(List<NoteEvent> a, List<NoteEvent> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i]) && a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameSections(List<Section> a, List<Section> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.label != y.label ||
          x.startMeasure != y.startMeasure ||
          x.startNote != y.startNote) {
        return false;
      }
    }
    return true;
  }
}

// Diatonic staff order; stepping ▲/▼ moves one position (octave wraps at B↔C).
const _steps = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const _stepSemitone = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
// Explicit alter for each forced accidental; 'none' (null) instead follows the
// key signature via KeySignature.defaultAlter.
const _accidentalAlter = {'flat': -1, 'natural': 0, 'sharp': 1};

final measureEditProvider =
    StateNotifierProvider<MeasureEditController, MeasureEditSession?>(
        MeasureEditController.new);

class MeasureEditController extends StateNotifier<MeasureEditSession?> {
  final Ref _ref;
  Timer? _draftTimer;

  MeasureEditController(this._ref) : super(null);

  /// How long the bar waits after the last edit before re-engraving the piece
  /// with it. The cards update at once; a full engrave is ~1s on a phone, so
  /// tapping ▲ five times should cost one, not five.
  static const draftDelay = Duration(milliseconds: 250);

  // ── Session lifecycle ──────────────────────────────────────────────────

  /// Opens [measureNumber] for editing. Returns false when there's no parsed
  /// piece to edit.
  bool start(int measureNumber) {
    final piece = _ref.read(selectedPieceProvider);
    final parsed = _ref.read(parsedPieceProvider).valueOrNull;
    if (piece == null || parsed == null || parsed.measures.isEmpty) {
      return false;
    }
    _clearDraft();
    var index = parsed.measures.indexWhere((m) => m.number == measureNumber);
    if (index < 0) {
      index = (measureNumber - 1).clamp(0, parsed.measures.length - 1);
    }
    final measure = parsed.measures[index];
    final isFirst = index == 0;
    final timeChange =
        isFirst ? parsed.openingMeter : measure.timeChange;
    // Repair the chord invariant up front — OMR output can carry a stray
    // leading <chord/> or a member whose duration drifted from its primary.
    final notes = ChordEditor.normalize(measure.notes);
    final sections = List<Section>.of(piece.sections);
    state = MeasureEditSession(
      pieceId: piece.id,
      measureNumber: measure.number,
      notes: notes,
      originalNotes: notes,
      selectedIndex: notes.isEmpty ? null : 0,
      repeatStart: measure.repeatStart,
      repeatEnd: measure.repeatEnd,
      originalRepeatStart: measure.repeatStart,
      originalRepeatEnd: measure.repeatEnd,
      sectionStarts: sections,
      originalSectionStarts: List.of(sections),
      timeChange: timeChange,
      originalTimeChange: timeChange,
      meterBefore: isFirst ? parsed.openingMeter : parsed.meterAt(index - 1),
      isFirstMeasure: isFirst,
    );
    return true;
  }

  /// Discards the session and its draft; the piece shows the file again.
  void cancel() {
    _clearDraft();
    state = null;
  }

  void _clearDraft() {
    _draftTimer?.cancel();
    if (_ref.read(measureDraftProvider) != null) {
      _ref.read(measureDraftProvider.notifier).state = null;
    }
  }

  void _update(MeasureEditSession next, {bool redraft = true}) {
    state = next;
    if (!redraft) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(draftDelay, _publishDraft);
  }

  void _publishDraft() {
    final s = state;
    if (s == null) return;
    final parsed = _ref.read(parsedPieceProvider).valueOrNull;
    final draft = _ref.read(measureDraftProvider.notifier);
    if (!s.notesChanged && !s.repeatsChanged) {
      if (draft.state != null) draft.state = null;
      return;
    }
    draft.state = MeasureDraft(
      pieceId: s.pieceId,
      measureNumber: s.measureNumber,
      notes: s.notes,
      divisions: parsed?.divisions ?? draft.state?.divisions ?? 1,
      repeatStart: s.repeatStart,
      repeatEnd: s.repeatEnd,
    );
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    super.dispose();
  }

  // ── Selection ──────────────────────────────────────────────────────────

  void select(int i) {
    final s = state;
    if (s == null) return;
    _update(s.copyWith(selectedIndex: i), redraft: false);
  }

  // ── Pitch math ─────────────────────────────────────────────────────────

  int get _keyFifths =>
      _ref.read(parsedPieceProvider).valueOrNull?.keyFifths ?? 0;

  static ({String step, int alter, int octave}) _parse(String pitch) {
    final m = RegExp(r'^([A-G])([#b]?)(\d)$').firstMatch(pitch);
    if (m == null) return (step: 'B', alter: 0, octave: 4);
    final alter = m.group(2) == '#' ? 1 : (m.group(2) == 'b' ? -1 : 0);
    return (step: m.group(1)!, alter: alter, octave: int.parse(m.group(3)!));
  }

  static String _pitchString(String step, int alter, int octave) =>
      '$step${alter > 0 ? '#' : (alter < 0 ? 'b' : '')}$octave';

  static int _midi(String step, int alter, int octave) =>
      (_stepSemitone[step] ?? 0) + (octave + 1) * 12 + alter;

  void stepPitch(int dir) {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null) return;
    final p = _parse(s.notes[i].pitch);
    var idx = _steps.indexOf(p.step) + dir;
    var octave = p.octave;
    if (idx > 6) {
      idx = 0;
      octave += 1;
    } else if (idx < 0) {
      idx = 6;
      octave -= 1;
    }
    final step = _steps[idx];
    final alter = KeySignature.defaultAlter(_keyFifths, step);
    // ChordEditor.repitch drops the now-stale fingering but carries the
    // structural fields (chord membership, chord symbol, rhythm) through.
    _update(s.copyWith(
      notes: ChordEditor.replaceAt(
        s.notes,
        i,
        ChordEditor.repitch(
          s.notes[i],
          pitch: _pitchString(step, alter, octave),
          midiNumber: _midi(step, alter, octave),
          octave: octave,
        ),
      ),
    ));
  }

  void setAccidental(String? kind) {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null || s.notes[i].isRest) return;
    final n = s.notes[i];
    final p = _parse(n.pitch);
    final alter =
        _accidentalAlter[kind] ?? KeySignature.defaultAlter(_keyFifths, p.step);
    final newMidi = _midi(p.step, alter, p.octave);
    // Keep the fingering only while the sounding pitch is unchanged (e.g.
    // clearing a courtesy natural); a real pitch change invalidates it.
    _update(s.copyWith(
      notes: ChordEditor.replaceAt(
        s.notes,
        i,
        ChordEditor.repitch(
          n,
          pitch: _pitchString(p.step, alter, p.octave),
          midiNumber: newMidi,
          octave: p.octave,
          displayAccidental: kind,
          keepFingering: newMidi == n.midiNumber,
        ),
      ),
    ));
  }

  // ── Open string / 4th finger ───────────────────────────────────────────

  /// Pins the selected note to the open string (0) or the 4th finger (4), or
  /// with null hands it back to the piece's setting. Stored as the note's
  /// `<fingering>` ([NoteEvent.scoreFinger]), which Save writes and
  /// [FingeringMapper] obeys, so the choice reaches every view.
  void setStringChoice(int? finger) {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null || s.notes[i].isRest) return;
    final n = s.notes[i];
    if (!FingeringMapper.hasFourthFingerChoice(n.midiNumber)) return;
    final notes = ChordEditor.replaceAt(
      s.notes,
      i,
      finger == null
          ? n.copyWith(clearScoreFinger: true)
          : n.copyWith(scoreFinger: finger),
    );
    _update(s.copyWith(notes: _refingered(s.measureNumber, notes)));
  }

  /// [notes] fingered as they will be once saved: the whole piece with this
  /// measure swapped in goes back through the mapper, so Auto sees the same
  /// neighbours (across the barlines too) as the piece view will.
  List<NoteEvent> _refingered(int measureNumber, List<NoteEvent> notes) {
    final parsed = _ref.read(parsedPieceProvider).valueOrNull;
    if (parsed == null) return notes;
    final k = parsed.measures.indexWhere((m) => m.number == measureNumber);
    if (k < 0) return notes;
    final measures = [...parsed.measures];
    measures[k] = measures[k].copyWithNotes(notes);
    final mapped = _ref.read(fingeringMapperProvider).map(
        parsed.copyWithMeasures(measures),
        preference: _ref.read(violinStringPreferenceProvider));
    return mapped.measures[k].notes;
  }

  // ── Rhythm and structure ───────────────────────────────────────────────

  void changeDuration({required bool longer}) {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null) return;
    // Step from the PRIMARY, not the selected member, so a member that somehow
    // drifted can't propagate its value to the rest of the stack.
    final p = s.notes[ChordEditor.primaryIndexOf(s.notes, i)];
    final step = longer
        ? DurationStep.next(p.noteValue, p.dotted)
        : DurationStep.previous(p.noteValue, p.dotted);
    _update(s.copyWith(notes: ChordEditor.setDuration(s.notes, i, step)));
  }

  void toggleRest() {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null) return;
    _update(s.copyWith(notes: ChordEditor.toggleRest(s.notes, i)));
  }

  /// Joins the selected note to the previous note's stem, or detaches it.
  void toggleStack() {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null) return;
    final notes = ChordEditor.canUnstack(s.notes, i)
        ? ChordEditor.unstack(s.notes, i)
        : ChordEditor.stack(s.notes, i);
    // A marker on a note that just became a member has to follow its stack's
    // primary — a section can't begin mid-stem.
    _update(s.copyWith(
      notes: notes,
      sectionStarts: ChordEditor.normalizeMarkers(
          notes, s.sectionStarts, s.measureNumber),
    ));
  }

  void insert() {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null) return;
    final n = s.notes[i];
    final r = ChordEditor.insertAfter(
      s.notes,
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
    _update(s.copyWith(notes: r.notes, selectedIndex: r.selectedIndex));
  }

  void delete() {
    final s = state;
    final i = s?.selectedIndex;
    if (s == null || i == null) return;
    final r = ChordEditor.deleteAt(s.notes, i);
    _update(s.copyWith(
      notes: r.notes,
      selectedIndex: r.selectedIndex,
      clearSelection: r.selectedIndex == null,
    ));
  }

  void toggleRepeatStart() {
    final s = state;
    if (s == null) return;
    _update(s.copyWith(repeatStart: !s.repeatStart));
  }

  void toggleRepeatEnd() {
    final s = state;
    if (s == null) return;
    _update(s.copyWith(repeatEnd: !s.repeatEnd));
  }

  /// Sets (or with an empty [label], clears) the section marker at the
  /// selected note. Applied on Save, not drafted: markers aren't MusicXML.
  void setSectionMarker(String label) {
    final s = state;
    final i = s?.markerIndex;
    if (s == null || i == null) return;
    final next = s.sectionStarts
        .where((m) => !(m.startMeasure == s.measureNumber && m.startNote == i))
        .toList();
    if (label.isNotEmpty) {
      next.add(Section(
          label: label, startMeasure: s.measureNumber, startNote: i));
    }
    _update(s.copyWith(sectionStarts: next), redraft: false);
  }

  /// Sets the time signature this bar starts — or with null, makes it carry
  /// on in the meter before it (not on the first bar, which always has one).
  /// Applied on Save, not drafted.
  void setTimeChange(Meter? meter) {
    final s = state;
    if (s == null) return;
    if (meter == null && s.isFirstMeasure) return;
    _update(
        meter == null
            ? s.copyWith(clearTimeChange: true)
            : s.copyWith(timeChange: meter),
        redraft: false);
  }

  // ── Persistence ────────────────────────────────────────────────────────

  /// Writes the bar (and the section markers) and closes the session. Throws
  /// on failure, leaving the session open so nothing typed is lost.
  Future<void> save() async {
    final s = state;
    final piece = _ref.read(selectedPieceProvider);
    final parsed = _ref.read(parsedPieceProvider).valueOrNull;
    if (s == null || piece == null || parsed == null) return;
    if (!s.isDirty) {
      cancel();
      return;
    }
    state = s.copyWith(saving: true);
    try {
      final repo = _ref.read(pieceRepositoryProvider);
      var xml = await repo.loadMusicXml(piece);
      if (s.notesChanged || s.repeatsChanged) {
        xml = MeasureXmlEditor.replaceMeasureNotes(
            xml, s.measureNumber, s.notes, parsed.divisions);
        xml = MeasureXmlEditor.setMeasureRepeats(xml, s.measureNumber,
            start: s.repeatStart, end: s.repeatEnd);
      }
      if (s.timeChanged) {
        final m = s.timeChange;
        xml = m == null
            ? MeasureXmlEditor.removeTimeChange(xml, s.measureNumber)
            : MeasureXmlEditor.setTimeChange(xml, s.measureNumber,
                beats: m.beats, beatType: m.beatType);
      }
      // Materializes a writable copy on a bundled fixture's first edit, so the
      // returned piece is always file-backed.
      final updated = await repo.writeEditedMusicXml(piece, xml);
      await repo.saveSections(piece.id, s.sectionStarts);
      _draftTimer?.cancel();
      state = null;
      // The file now says what the draft did; drop the draft in the same
      // breath as the piece swap so the views re-read once.
      _ref.read(measureDraftProvider.notifier).state = null;
      _ref.read(selectedPieceProvider.notifier).state =
          updated.copyWith(sections: s.sectionStarts);
      _ref.invalidate(piecesProvider);
      _ref.invalidate(pieceMusicXmlProvider);
    } catch (_) {
      if (mounted && state != null) state = state!.copyWith(saving: false);
      rethrow;
    }
  }
}
